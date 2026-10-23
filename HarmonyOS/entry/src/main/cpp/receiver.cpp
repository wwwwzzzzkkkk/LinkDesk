#include "audio_receiver.h"
#include "microphone_sender.h"
#include "microphone_control.h"
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <vector>
#include <map>
#include <ctime>
#include <napi/native_api.h>
#include <hilog/log.h>
#include <native_window/external_window.h>
#include <native_vsync/native_vsync.h>
#include <window_manager/oh_display_manager.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_videodecoder.h>
#include <multimedia/player_framework/native_avformat.h>

namespace {
constexpr uint16_t PORT = 24832;
constexpr uint16_t CONTROL_PORT = 24834;
constexpr uint32_t MAX_FRAME = 8 * 1024 * 1024;
uint32_t U32(const uint8_t *p) { return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3]; }
uint64_t U64(const uint8_t *p) { return (uint64_t(U32(p)) << 32) | U32(p + 4); }
struct Input { uint32_t index; OH_AVBuffer *buffer; };
int64_t LocalTimeNs() {
    timespec value{};
    clock_gettime(CLOCK_MONOTONIC, &value);
    return static_cast<int64_t>(value.tv_sec) * 1000000000LL + value.tv_nsec;
}
struct FrameTiming { int64_t receivedNs; int64_t submittedNs; };

class Receiver {
public:
    static Receiver &Get() { static Receiver instance; return instance; }
    ~Receiver() { Stop(); }
    void SetMicrophoneRequested(bool enabled){microphoneControl_.SetRequested(enabled);}
    void SetMicrophoneEnabled(bool enabled){if(enabled)microphone_.Start();else microphone_.Stop();}
    void Start(uint64_t surface, uint64_t windowId = 0) {
        Stop();
        for (const char *mime : {OH_AVCODEC_MIMETYPE_VIDEO_AVC, OH_AVCODEC_MIMETYPE_VIDEO_HEVC}) {
            OH_AVCapability *cap = OH_AVCodec_GetCapabilityByCategory(mime, false, HARDWARE);
            OH_AVRange range{};
            if (cap && OH_AVCapability_GetVideoFrameRateRangeForSize(cap, 2880, 1920, &range) == AV_ERR_OK) {
                OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "HFR_CAP codec=%{public}s name=%{public}s min=%{public}d max=%{public}d supports120=%{public}d supports144=%{public}d",
                    mime, OH_AVCapability_GetName(cap), range.minVal, range.maxVal,
                    OH_AVCapability_AreVideoSizeAndFrameRateSupported(cap, 2880, 1920, 120),
                    OH_AVCapability_AreVideoSizeAndFrameRateSupported(cap, 2880, 1920, 144));
            }
        }
        timedRenderRejected_ = false; timedSubmissions_ = 0; lastDecodeUs_ = 0; lastReceiveUs_ = 0; lastSubmitUs_ = 0;
        surface_ = surface; windowId_ = windowId; frames_ = 0; bytes_ = 0; error_ = 0; hostRequestState_ = 0; active_ = true;
        audio_.Start();
        microphoneControl_.Start();
        worker_ = std::thread([this] { Loop(); });
        hostThread_ = std::thread([this] { RequestHostLoop(); });
    }
    void Stop() {
        active_ = false; cv_.notify_all(); hostCv_.notify_all();
        microphone_.Stop();
        microphoneControl_.Stop();
        audio_.Stop();
        { std::lock_guard<std::mutex> lock(socketMutex_); if (fd_ >= 0) shutdown(fd_, SHUT_RDWR); }
        if (worker_.joinable()) worker_.join();
        if (hostThread_.joinable()) hostThread_.join();
        state_ = 0;
    }
    std::string Stats() {
        uint32_t refresh = 0;
        screenHz_ = OH_NativeDisplayManager_GetDefaultDisplayRefreshRate(&refresh) == DISPLAY_MANAGER_OK ? refresh : 0;
        return "{\"microphoneRequested\":" + std::string(microphoneControl_.Requested() ? "true" : "false") + ",\"microphoneState\":" + std::to_string(microphone_.State()) + ",\"hostRequestState\":" + std::to_string(hostRequestState_.load()) + ",\"audioState\":" + std::to_string(audio_.State()) + ",\"audioFrames\":" + std::to_string(audio_.Played()) + ",\"state\":" + std::to_string(state_.load()) + ",\"frames\":" + std::to_string(frames_.load()) +
            ",\"bytes\":" + std::to_string(bytes_.load()) + ",\"error\":" + std::to_string(error_.load()) +
            ",\"width\":" + std::to_string(width_.load()) + ",\"height\":" + std::to_string(height_.load()) + ",\"targetFPS\":" + std::to_string(targetFPS_.load()) + ",\"vsyncHz\":" + std::to_string(vsyncHz_.load()) + ",\"screenHz\":" + std::to_string(screenHz_.load()) +
            ",\"latestMode\":" + (latestMode_.load() ? "true" : "false") + ",\"timedSupported\":" + (timedRenderRejected_.load() ? "false" : "true") +
            ",\"timedSubmissions\":" + std::to_string(timedSubmissions_.load()) + ",\"receiveSubmitUs\":" + std::to_string(lastReceiveUs_.load()) +
            ",\"decodeUs\":" + std::to_string(lastDecodeUs_.load()) + ",\"submitUs\":" + std::to_string(lastSubmitUs_.load()) + "}";
    }
    uint64_t Frames() const { return frames_.load(); }
    void SetLatestMode(bool enabled) {
        latestMode_ = enabled;
        std::lock_guard<std::mutex> lock(timingMutex_);
        metricFrames_ = 0; decodeTotalUs_ = receiveTotalUs_ = submitTotalUs_ = 0;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "DISPLAY_MODE latest=%{public}d", enabled);
    }
private:
    std::atomic<bool> active_{false}, codecFailed_{false};
    std::atomic<int> state_{0}, error_{0}, hostRequestState_{0};
    std::atomic<uint64_t> frames_{0}, bytes_{0};
    std::atomic<uint32_t> width_{1920}, height_{1280};
    std::atomic<uint32_t> targetFPS_{60}, vsyncHz_{0}, screenHz_{0};
    bool hevc_ = false;
    OH_NativeVSync *vsync_ = nullptr;
    std::mutex vsyncMutex_;
    uint64_t surface_ = 0;
    uint64_t windowId_ = 0;
    int fd_ = -1;
    OH_AVCodec *codec_ = nullptr;
    OHNativeWindow *window_ = nullptr;
    bool codecStarted_ = false;
    AudioReceiver audio_;
    MicrophoneSender microphone_;
    MicrophoneControl microphoneControl_;
    std::thread worker_, hostThread_;
    std::mutex socketMutex_, inputMutex_;
    std::condition_variable cv_;
    std::mutex hostMutex_;
    std::condition_variable hostCv_;
    std::queue<Input> inputs_;
    std::atomic<bool> latestMode_{true}, timedRenderRejected_{false};
    std::atomic<uint64_t> timedSubmissions_{0};
    std::atomic<int64_t> lastDecodeUs_{0}, lastReceiveUs_{0}, lastSubmitUs_{0};
    std::mutex timingMutex_;
    std::map<int64_t, FrameTiming> frameTimings_;
    uint32_t metricFrames_ = 0;
    int64_t decodeTotalUs_ = 0, receiveTotalUs_ = 0, submitTotalUs_ = 0;

    void RequestHostLoop() {
        unsigned attempts = 0;
        while (active_ && hostRequestState_ != 3) {
            if (state_ == 3) {
                std::unique_lock<std::mutex> lock(hostMutex_);
                hostCv_.wait_for(lock, std::chrono::seconds(1), [this] { return !active_; });
                continue;
            }
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd >= 0) {
                timeval timeout{0, 500000};
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
                sockaddr_in address{}; address.sin_family = AF_INET;
                address.sin_port = htons(CONTROL_PORT); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
                if (connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0) {
                    const char request[8] = {'L','D','S','T','A','R','T','1'};
                    char reply = 0;
                    if (send(fd, request, sizeof(request), MSG_NOSIGNAL) == sizeof(request) && recv(fd, &reply, 1, 0) == 1) {
                        if (reply == 'S') hostRequestState_ = 1;
                        else if (reply == 'P') hostRequestState_ = 3;
                        else if (reply == 'U') hostRequestState_ = 5;
                    }
                }
                close(fd);
            }
            if (++attempts >= 5 && hostRequestState_ == 0) hostRequestState_ = 4;
            std::unique_lock<std::mutex> lock(hostMutex_);
            hostCv_.wait_for(lock, std::chrono::seconds(1), [this] { return !active_; });
        }
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "CONTROL_START state=%{public}d video=%{public}d", hostRequestState_.load(), state_.load());
    }

    static void OnVsync(long long, void *context) {
        auto *self = static_cast<Receiver *>(context);
        std::lock_guard<std::mutex> lock(self->vsyncMutex_);
        if (!self->active_ || !self->vsync_) return;
        long long period = 0;
        if (OH_NativeVSync_GetPeriod(self->vsync_, &period) == 0 && period > 0) {
            uint32_t hz = (1000000000LL + period / 2) / period;
            if (self->vsyncHz_.exchange(hz) != hz) OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "HFR_VSYNC_ACTUAL hz=%{public}u target=%{public}u", hz, self->targetFPS_.load());
        }
        OH_NativeVSync_RequestFrame(self->vsync_, OnVsync, self);
    }
    void StartVsync(uint32_t fps) {
        if (fps <= 60) return;
        std::lock_guard<std::mutex> lock(vsyncMutex_);
        vsync_ = windowId_ ? OH_NativeVSync_Create_ForAssociatedWindow(windowId_, "LinkDeskHFR", 11) : OH_NativeVSync_Create("LinkDeskHFR", 11);
        if (!vsync_) return;
        OH_NativeVSync_ExpectedRateRange range{static_cast<int32_t>(fps), static_cast<int32_t>(fps), static_cast<int32_t>(fps)};
        int result = OH_NativeVSync_SetExpectedFrameRateRange(vsync_, &range);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "HFR_VSYNC request=%{public}u result=%{public}d", fps, result);
        OH_NativeVSync_RequestFrame(vsync_, OnVsync, this);
    }
    void StopVsync() {
        OH_NativeVSync *old = nullptr;
        { std::lock_guard<std::mutex> lock(vsyncMutex_); old = vsync_; vsync_ = nullptr; }
        if (old) OH_NativeVSync_Destroy(old);
        vsyncHz_ = 0;
    }

    static void OnError(OH_AVCodec *, int32_t error, void *context) {
        auto *self = static_cast<Receiver *>(context);
        self->error_ = error; self->codecFailed_ = true; self->cv_.notify_all();
        std::lock_guard<std::mutex> lock(self->socketMutex_);
        if (self->fd_ >= 0) shutdown(self->fd_, SHUT_RDWR);
        OH_LOG_Print(LOG_APP, LOG_ERROR, 0x3301, "LinkDesk", "Decoder error %{public}d", error);
    }
    static void OnChanged(OH_AVCodec *, OH_AVFormat *, void *) {}
    static void OnInput(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *context) {
        auto *self = static_cast<Receiver *>(context);
        { std::lock_guard<std::mutex> lock(self->inputMutex_); self->inputs_.push({index, buffer}); }
        self->cv_.notify_all();
    }
    static void OnOutput(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *context) {
        auto *self = static_cast<Receiver *>(context);
        OH_AVCodecBufferAttr attr{};
        bool hasTimestamp = OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK;
        int64_t decodedNs = LocalTimeNs();
        FrameTiming timing{};
        if (hasTimestamp) {
            std::lock_guard<std::mutex> lock(self->timingMutex_);
            auto it = self->frameTimings_.find(attr.pts);
            if (it != self->frameTimings_.end()) { timing = it->second; self->frameTimings_.erase(it); }
        }
        bool timed = self->surface_ && self->latestMode_ && !self->timedRenderRejected_;
        OH_AVErrCode result;
        if (!self->surface_) result = OH_VideoDecoder_FreeOutputBuffer(codec, index);
        else if (timed) {
            // This API keeps only the latest buffer addressed to the same VSYNC.
            // Use the tablet's local clock, never the Mac's unrelated PTS epoch.
            result = OH_VideoDecoder_RenderOutputBufferAtTime(codec, index, decodedNs);
            if (result == AV_ERR_OK) self->timedSubmissions_++;
            else {
                self->timedRenderRejected_ = true;
                OH_LOG_Print(LOG_APP, LOG_WARN, 0x3301, "LinkDesk", "TIMED_RENDER_FALLBACK error=%{public}d", result);
                result = OH_VideoDecoder_RenderOutputBuffer(codec, index);
            }
        } else result = OH_VideoDecoder_RenderOutputBuffer(codec, index);
        if (result == AV_ERR_OK) {
            self->frames_++; self->state_ = 3;
            int64_t renderedNs = LocalTimeNs();
            if (timing.submittedNs > 0 && decodedNs >= timing.submittedNs) {
                int64_t decodeUs = (decodedNs - timing.submittedNs) / 1000;
                int64_t receiveUs = (renderedNs - timing.receivedNs) / 1000;
                int64_t submitUs = (renderedNs - decodedNs) / 1000;
                self->lastDecodeUs_ = decodeUs; self->lastReceiveUs_ = receiveUs; self->lastSubmitUs_ = submitUs;
                std::lock_guard<std::mutex> lock(self->timingMutex_);
                self->decodeTotalUs_ += decodeUs; self->receiveTotalUs_ += receiveUs; self->submitTotalUs_ += submitUs;
                if (++self->metricFrames_ == 120) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "PIPELINE_120 latest=%{public}d timed_ok=%{public}d receive_submit_us=%{public}lld decode_us=%{public}lld submit_us=%{public}lld",
                        self->latestMode_.load(), !self->timedRenderRejected_.load(),
                        static_cast<long long>(self->receiveTotalUs_ / 120), static_cast<long long>(self->decodeTotalUs_ / 120), static_cast<long long>(self->submitTotalUs_ / 120));
                    self->metricFrames_ = 0; self->decodeTotalUs_ = self->receiveTotalUs_ = self->submitTotalUs_ = 0;
                }
            }
            if (hasTimestamp && attr.pts > 0) {
                uint8_t ack[16] = {'L', 'D', 'A', '1'};
                uint32_t refresh = self->screenHz_.load();
                for (int i = 0; i < 4; ++i) ack[4 + i] = static_cast<uint8_t>(refresh >> (24 - i * 8));
                uint64_t timestamp = static_cast<uint64_t>(attr.pts);
                for (int i = 0; i < 8; ++i) ack[8 + i] = static_cast<uint8_t>(timestamp >> (56 - i * 8));
                std::lock_guard<std::mutex> lock(self->socketMutex_);
                if (self->fd_ >= 0) {
                    ssize_t n = send(self->fd_, ack, sizeof(ack), MSG_DONTWAIT | MSG_NOSIGNAL);
                    // Never silently lose feedback: the sender uses it to bound outstanding frames.
                    if (n != sizeof(ack)) shutdown(self->fd_, SHUT_RDWR);
                }
            }
        }
    }
    bool Read(void *buffer, size_t length) {
        auto *p = static_cast<uint8_t *>(buffer);
        while (length && active_ && !codecFailed_) {
            ssize_t n = recv(fd_, p, length, 0);
            if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            if (n <= 0) return false;
            p += n; length -= n; bytes_ += n;
        }
        return length == 0;
    }
    bool Connect() {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return false;
        { std::lock_guard<std::mutex> lock(socketMutex_); fd_ = fd; }
        timeval timeout{3, 0};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int yes = 1; setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(PORT); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        return active_ && connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0;
    }
    bool Configure(uint32_t width, uint32_t height, uint32_t fps) {
        if (surface_ && (OH_NativeWindow_CreateNativeWindowFromSurfaceId(surface_, &window_) != 0 || !window_)) { error_ = -101; return false; }
        const char *mime = hevc_ ? OH_AVCODEC_MIMETYPE_VIDEO_HEVC : OH_AVCODEC_MIMETYPE_VIDEO_AVC;
        OH_AVCapability *capability = OH_AVCodec_GetCapabilityByCategory(mime, false, HARDWARE);
        const char *name = capability ? OH_AVCapability_GetName(capability) : nullptr;
        codec_ = name ? OH_VideoDecoder_CreateByName(name) : OH_VideoDecoder_CreateByMime(mime);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "HFR_DECODER codec=%{public}s target=%{public}u width=%{public}u height=%{public}u", name ? name : mime, fps, width, height);
        if (!codec_) { error_ = -102; return false; }
        OH_AVCodecCallback callbacks{OnError, OnChanged, OnInput, OnOutput};
        if (OH_VideoDecoder_RegisterCallback(codec_, callbacks, this) != AV_ERR_OK) { error_ = -103; return false; }
        OH_AVFormat *format = OH_AVFormat_Create();
        if (!format) return false;
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
        OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, fps);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, MAX_FRAME);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x3301, "LinkDesk", "DECODER_LATENCY low_latency=%{public}d",
            capability && OH_AVCapability_IsFeatureSupported(capability, VIDEO_LOW_LATENCY));
        OH_AVErrCode result = OH_VideoDecoder_Configure(codec_, format);
        OH_AVFormat_Destroy(format);
        if (result != AV_ERR_OK) { error_ = result; return false; }
        if ((window_ && OH_VideoDecoder_SetSurface(codec_, window_) != AV_ERR_OK) || OH_VideoDecoder_Prepare(codec_) != AV_ERR_OK) { error_ = -104; return false; }
        result = OH_VideoDecoder_Start(codec_);
        codecStarted_ = result == AV_ERR_OK;
        if (!codecStarted_) error_ = result;
        else StartVsync(fps);
        return codecStarted_;
    }
    bool Decode(const std::vector<uint8_t> &data, uint32_t flags, int64_t pts, int64_t receivedNs) {
        Input input{};
        {
            std::unique_lock<std::mutex> lock(inputMutex_);
            if (!cv_.wait_for(lock, std::chrono::seconds(2), [this] { return !active_ || codecFailed_ || !inputs_.empty(); })) { error_ = -105; return false; }
            if (!active_ || codecFailed_ || inputs_.empty()) return false;
            input = inputs_.front(); inputs_.pop();
        }
        uint8_t *destination = OH_AVBuffer_GetAddr(input.buffer);
        int32_t capacity = OH_AVBuffer_GetCapacity(input.buffer);
        if (!destination || capacity < 0 || static_cast<size_t>(capacity) < data.size()) { error_ = -106; return false; }
        memcpy(destination, data.data(), data.size());
        OH_AVCodecBufferAttr attr{}; attr.pts = pts; attr.size = static_cast<int32_t>(data.size());
        attr.flags = flags & 1 ? AVCODEC_BUFFER_FLAGS_SYNC_FRAME : AVCODEC_BUFFER_FLAGS_NONE;
        if (OH_AVBuffer_SetBufferAttr(input.buffer, &attr) != AV_ERR_OK) return false;
        {
            std::lock_guard<std::mutex> lock(timingMutex_);
            frameTimings_[pts] = {receivedNs, LocalTimeNs()};
            while (frameTimings_.size() > 120) frameTimings_.erase(frameTimings_.begin());
        }
        OH_AVErrCode result = OH_VideoDecoder_PushInputBuffer(codec_, input.index);
        if (result != AV_ERR_OK) error_ = result;
        return result == AV_ERR_OK;
    }
    void Cleanup() {
        StopVsync();
        if (codec_) {
            if (codecStarted_) OH_VideoDecoder_Stop(codec_);
            OH_VideoDecoder_Destroy(codec_); codec_ = nullptr; codecStarted_ = false;
        }
        { std::lock_guard<std::mutex> lock(inputMutex_); std::queue<Input> empty; inputs_.swap(empty); }
        { std::lock_guard<std::mutex> lock(timingMutex_); frameTimings_.clear(); metricFrames_ = 0; decodeTotalUs_ = receiveTotalUs_ = submitTotalUs_ = 0; }
        if (window_) { OH_NativeWindow_DestroyNativeWindow(window_); window_ = nullptr; }
        { std::lock_guard<std::mutex> lock(socketMutex_); if (fd_ >= 0) { close(fd_); fd_ = -1; } }
    }
    void Session() {
        if (!Connect()) return;
        uint8_t header[16];
        if (!Read(header, sizeof(header))) return;
        uint32_t width = U32(header + 4), height = U32(header + 8), fps = U32(header + 12);
        bool supportedSize = (width == 1920 && height == 1280) || (width == 2880 && height == 1920);
        hevc_ = memcmp(header, "LDH1", 4) == 0;
        if ((!hevc_ && memcmp(header, "LDV1", 4)) || !supportedSize || (fps != 60 && fps != 120 && fps != 144)) { error_ = -100; return; }
        targetFPS_ = fps;
        width_ = width; height_ = height;
        state_ = 2;
        if (!Configure(width, height, fps)) return;
        bool haveKeyframe = false;
        while (active_ && !codecFailed_) {
            uint8_t packet[16]; if (!Read(packet, sizeof(packet))) break;
            uint32_t length = U32(packet), flags = U32(packet + 4);
            if (!length || length > MAX_FRAME || flags > 1) { error_ = -107; break; }
            std::vector<uint8_t> data(length); if (!Read(data.data(), data.size())) break;
            if (!haveKeyframe && !(flags & 1)) continue;
            haveKeyframe = true;
            if (!Decode(data, flags, static_cast<int64_t>(U64(packet + 8)), LocalTimeNs())) break;
        }
    }
    void Loop() {
        while (active_) {
            state_ = 1; codecFailed_ = false;
            Session(); Cleanup();
            if (active_) {
                state_ = 1;
                std::unique_lock<std::mutex> lock(inputMutex_);
                cv_.wait_for(lock, std::chrono::seconds(1), [this] { return !active_; });
            }
        }
        Cleanup();
    }
};

napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value argv[2]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    char value[64]{}; size_t length = 0;
    if (argc < 1 || napi_get_value_string_utf8(env, argv[0], value, sizeof(value), &length) != napi_ok) {
        napi_throw_type_error(env, nullptr, "A surface ID is required"); return nullptr;
    }
    char *end = nullptr; uint64_t surface = strtoull(value, &end, 10);
    if (!surface || !end || *end) { napi_throw_type_error(env, nullptr, "Invalid surface ID"); return nullptr; }
    uint32_t windowId = 0;
    if (argc > 1 && napi_get_value_uint32(env, argv[1], &windowId) != napi_ok) {
        napi_throw_type_error(env, nullptr, "Invalid window ID"); return nullptr;
    }
    Receiver::Get().Start(surface, windowId); napi_value out; napi_get_undefined(env, &out); return out;
}
napi_value Stop(napi_env env, napi_callback_info) { Receiver::Get().Stop(); napi_value out; napi_get_undefined(env, &out); return out; }
napi_value Stats(napi_env env, napi_callback_info) { auto stats = Receiver::Get().Stats(); napi_value out; napi_create_string_utf8(env, stats.c_str(), stats.size(), &out); return out; }
napi_value SetLatest(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value argv[1]; napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    bool enabled = true;
    if (argc != 1 || napi_get_value_bool(env, argv[0], &enabled) != napi_ok) { napi_throw_type_error(env, nullptr, "Expected a boolean"); return nullptr; }
    Receiver::Get().SetLatestMode(enabled); napi_value out; napi_get_undefined(env, &out); return out;
}
napi_value SetMicrophoneRequested(napi_env env,napi_callback_info info){
    size_t argc=1;napi_value argv[1];napi_get_cb_info(env,info,&argc,argv,nullptr,nullptr);
    bool enabled=false;
    if(argc!=1||napi_get_value_bool(env,argv[0],&enabled)!=napi_ok){napi_throw_type_error(env,nullptr,"Expected boolean");return nullptr;}
    Receiver::Get().SetMicrophoneRequested(enabled);napi_value out;napi_get_undefined(env,&out);return out;
}
napi_value SetMicrophone(napi_env env,napi_callback_info info){
    size_t argc=1;napi_value argv[1];napi_get_cb_info(env,info,&argc,argv,nullptr,nullptr);bool enabled=false;
    if(argc!=1||napi_get_value_bool(env,argv[0],&enabled)!=napi_ok){napi_throw_type_error(env,nullptr,"Expected boolean");return nullptr;}
    Receiver::Get().SetMicrophoneEnabled(enabled);napi_value out;napi_get_undefined(env,&out);return out;
}
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stats", nullptr, Stats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLatestMode", nullptr, SetLatest, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMicrophoneEnabled", nullptr, SetMicrophone, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMicrophoneRequested", nullptr, SetMicrophoneRequested, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties); return exports;
}
napi_module module{1, 0, nullptr, Init, "linkdesk", nullptr, {0}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
}

#ifdef LD_PROBE
// A non-installing USB/decoder test. This does not verify the ArkUI surface.
int main() {
    Receiver::Get().Start(0);
    for (int i = 0; i < 12; ++i) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
        printf("%s\n", Receiver::Get().Stats().c_str()); fflush(stdout);
    }
    bool pass = Receiver::Get().Frames() > 0;
    Receiver::Get().Stop();
    printf("USB_H264_DECODE_%s\n", pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
#endif
