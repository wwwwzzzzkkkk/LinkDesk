#include <arpa/inet.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <queue>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

#include <hilog/log.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avscreen_capture_base.h>
#include <napi/native_api.h>
#include <native_window/external_window.h>

namespace {
constexpr unsigned int MIRROR_LOG_DOMAIN = 0x3201;
constexpr const char *MIRROR_LOG_TAG = "InkBridgeMirror";
constexpr int32_t VIDEO_WIDTH = 2400;
constexpr int32_t VIDEO_HEIGHT = 1600;
constexpr int32_t VIDEO_FPS = 60;
constexpr int64_t VIDEO_BITRATE = 30000000;

struct EncodedBuffer {
    uint32_t index;
    OH_AVBuffer *buffer;
    OH_AVCodecBufferAttr attr;
};

class MirrorSender {
public:
    static MirrorSender &Instance()
    {
        static MirrorSender sender;
        return sender;
    }

    int Start(const std::string &host, uint16_t port)
    {
        Stop();
        host_ = host;
        port_ = port;
        streamEpoch_ = std::chrono::steady_clock::now();
        lastPresentationTime_ = 0;
        socketFd_ = Connect(host, port);
        if (socketFd_ < 0) {
            return -1;
        }
        if (!SendStreamHeader()) {
            Stop();
            return -2;
        }
        connected_.store(true);

        capture_ = OH_AVScreenCapture_Create();
        if (capture_ == nullptr) {
            Stop();
            return -3;
        }
        OH_AVScreenCapture_SetMicrophoneEnabled(capture_, false);
        OH_AVScreenCapture_SetErrorCallback(capture_, OnCaptureError, this);
        OH_AVScreenCapture_SetStateCallback(capture_, OnCaptureState, this);

        OH_AVScreenCaptureConfig captureConfig {};
        OH_AudioCaptureInfo audioCapture {};
        audioCapture.audioSampleRate = 48000;
        audioCapture.audioChannels = 2;
        audioCapture.audioSource = OH_ALL_PLAYBACK;
        OH_AudioEncInfo audioEncoder {};
        audioEncoder.audioBitrate = 128000;
        audioEncoder.audioCodecformat = OH_AudioCodecFormat::OH_AAC_LC;
        OH_AudioInfo audioInfo {};
        audioInfo.innerCapInfo = audioCapture;
        audioInfo.audioEncInfo = audioEncoder;
        OH_VideoCaptureInfo videoCapture {};
        videoCapture.videoFrameWidth = VIDEO_WIDTH;
        videoCapture.videoFrameHeight = VIDEO_HEIGHT;
        videoCapture.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
        OH_VideoEncInfo videoEncoder {};
        videoEncoder.videoCodec = OH_VideoCodecFormat::OH_H264;
        videoEncoder.videoBitrate = VIDEO_BITRATE;
        videoEncoder.videoFrameRate = VIDEO_FPS;
        OH_VideoInfo videoInfo {};
        videoInfo.videoCapInfo = videoCapture;
        videoInfo.videoEncInfo = videoEncoder;
        captureConfig.captureMode = OH_CAPTURE_HOME_SCREEN;
        captureConfig.dataType = OH_ORIGINAL_STREAM;
        captureConfig.audioInfo = audioInfo;
        captureConfig.videoInfo = videoInfo;
        if (OH_AVScreenCapture_Init(capture_, captureConfig) != AV_SCREEN_CAPTURE_ERR_OK) {
            Stop();
            return -4;
        }

        OH_AVCapability *capability = OH_AVCodec_GetCapability(OH_AVCODEC_MIMETYPE_VIDEO_AVC, true);
        const char *codecName = capability == nullptr ? nullptr : OH_AVCapability_GetName(capability);
        encoder_ = codecName == nullptr ? OH_VideoEncoder_CreateByMime(OH_AVCODEC_MIMETYPE_VIDEO_AVC)
                                        : OH_VideoEncoder_CreateByName(codecName);
        if (encoder_ == nullptr) {
            Stop();
            return -5;
        }

        OH_AVCodecCallback callback {OnEncoderError, OnStreamChanged, OnNeedInputBuffer, OnEncodedBuffer};
        if (OH_VideoEncoder_RegisterCallback(encoder_, callback, this) != AV_ERR_OK || !ConfigureEncoder()) {
            Stop();
            return -6;
        }

        OHNativeWindow *inputSurface = nullptr;
        if (OH_VideoEncoder_GetSurface(encoder_, &inputSurface) != AV_ERR_OK || inputSurface == nullptr ||
            OH_VideoEncoder_Prepare(encoder_) != AV_ERR_OK || OH_VideoEncoder_Start(encoder_) != AV_ERR_OK) {
            Stop();
            return -7;
        }

        acceptingBuffers_.store(true);
        running_.store(true);
        senderThread_ = std::thread(&MirrorSender::SenderLoop, this);
        int captureResult = OH_AVScreenCapture_StartScreenCaptureWithSurface(capture_, inputSurface);
        if (captureResult != AV_SCREEN_CAPTURE_ERR_OK) {
            Stop();
            return captureResult == 0 ? -8 : captureResult;
        }
        return 0;
    }

    int Stop()
    {
        acceptingBuffers_.store(false);
        running_.store(false);
        connected_.store(false);
        queueCondition_.notify_all();
        if (socketFd_ >= 0) {
            shutdown(socketFd_, SHUT_RDWR);
        }
        if (capture_ != nullptr) {
            OH_AVScreenCapture_StopScreenCapture(capture_);
        }
        if (encoder_ != nullptr) {
            OH_VideoEncoder_NotifyEndOfStream(encoder_);
        }
        if (senderThread_.joinable()) {
            senderThread_.join();
        }
        if (encoder_ != nullptr) {
            OH_VideoEncoder_Stop(encoder_);
        }
        {
            std::unique_lock<std::mutex> callbackLock(callbackMutex_);
            callbackCondition_.wait(callbackLock, [this] { return activeOutputCallbacks_ == 0; });
        }
        DrainBuffers();
        if (encoder_ != nullptr) {
            OH_VideoEncoder_Destroy(encoder_);
            encoder_ = nullptr;
        }
        if (capture_ != nullptr) {
            OH_AVScreenCapture_Release(capture_);
            capture_ = nullptr;
        }
        if (socketFd_ >= 0) {
            close(socketFd_);
            socketFd_ = -1;
        }
        return 0;
    }

    bool IsRunning() const { return running_.load(); }

private:
    bool ConfigureEncoder()
    {
        OH_AVFormat *format = OH_AVFormat_Create();
        if (format == nullptr) {
            return false;
        }
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, VIDEO_WIDTH);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, VIDEO_HEIGHT);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
        OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, static_cast<double>(VIDEO_FPS));
        OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, VIDEO_BITRATE);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, 1000);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AVC_PROFILE_HIGH);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENCODE_BITRATE_MODE, CBR);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
        OH_AVErrCode result = OH_VideoEncoder_Configure(encoder_, format);
        OH_AVFormat_Destroy(format);
        return result == AV_ERR_OK;
    }

    static int Connect(const std::string &host, uint16_t port)
    {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) {
            return -1;
        }
        int noDelay = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, sizeof(noDelay));
        int sendBuffer = 512 * 1024;
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBuffer, sizeof(sendBuffer));
        sockaddr_in address {};
        address.sin_family = AF_INET;
        address.sin_port = htons(port);
        if (inet_pton(AF_INET, host.c_str(), &address.sin_addr) != 1 ||
            connect(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
            close(fd);
            return -1;
        }
        return fd;
    }

    bool SendStreamHeader()
    {
        uint8_t header[16] = {'I', 'B', 'V', '1'};
        WriteU16(header + 4, static_cast<uint16_t>(VIDEO_WIDTH));
        WriteU16(header + 6, static_cast<uint16_t>(VIDEO_HEIGHT));
        header[8] = 1;
        header[9] = VIDEO_FPS;
        return SendAll(header, sizeof(header));
    }

    void SenderLoop()
    {
        while (running_.load()) {
            EncodedBuffer item {};
            {
                std::unique_lock<std::mutex> lock(queueMutex_);
                queueCondition_.wait(lock, [this] { return !running_.load() || !outputQueue_.empty(); });
                if (!running_.load() && outputQueue_.empty()) {
                    break;
                }
                item = outputQueue_.front();
                outputQueue_.pop();
            }
            uint8_t *data = item.buffer == nullptr ? nullptr : OH_AVBuffer_GetAddr(item.buffer);
            uint64_t presentationTime = 0;
            if ((item.attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) == 0) {
                presentationTime = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now() - streamEpoch_).count());
                if (presentationTime <= lastPresentationTime_) {
                    presentationTime = lastPresentationTime_ + 1;
                }
                lastPresentationTime_ = presentationTime;
            }
            bool sent = data != nullptr && item.attr.size > 0 && SendPacket(data + item.attr.offset,
                static_cast<uint32_t>(item.attr.size), presentationTime, static_cast<uint32_t>(item.attr.flags));
            if (encoder_ != nullptr) {
                OH_VideoEncoder_FreeOutputBuffer(encoder_, item.index);
            }
            if (!sent) {
                if (!Reconnect()) {
                    break;
                }
            }
        }
    }

    bool Reconnect()
    {
        connected_.store(false);
        if (socketFd_ >= 0) {
            shutdown(socketFd_, SHUT_RDWR);
            close(socketFd_);
            socketFd_ = -1;
        }
        DrainBuffers();
        while (running_.load()) {
            int reconnected = Connect(host_, port_);
            if (reconnected >= 0) {
                socketFd_ = reconnected;
                if (SendStreamHeader()) {
                    connected_.store(true);
                    RequestKeyFrame();
                    return true;
                }
                close(reconnected);
                socketFd_ = -1;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(350));
        }
        return false;
    }

    void RequestKeyFrame()
    {
        if (encoder_ == nullptr) {
            return;
        }
        OH_AVFormat *format = OH_AVFormat_Create();
        if (format == nullptr) {
            return;
        }
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_REQUEST_I_FRAME, 1);
        OH_VideoEncoder_SetParameter(encoder_, format);
        OH_AVFormat_Destroy(format);
    }

    bool SendPacket(const uint8_t *payload, uint32_t length, uint64_t pts, uint32_t flags)
    {
        uint8_t header[16] {};
        WriteU32(header, length);
        WriteU64(header + 4, pts);
        WriteU32(header + 12, flags);
        return SendAll(header, sizeof(header)) && SendAll(payload, length);
    }

    bool SendAll(const void *bytes, size_t length)
    {
        const uint8_t *cursor = static_cast<const uint8_t *>(bytes);
        size_t sent = 0;
        while (sent < length && socketFd_ >= 0) {
            ssize_t count = send(socketFd_, cursor + sent, length - sent, MSG_NOSIGNAL);
            if (count <= 0) {
                return false;
            }
            sent += static_cast<size_t>(count);
        }
        return sent == length;
    }

    void DrainBuffers()
    {
        std::lock_guard<std::mutex> lock(queueMutex_);
        while (!outputQueue_.empty()) {
            if (encoder_ != nullptr) {
                OH_VideoEncoder_FreeOutputBuffer(encoder_, outputQueue_.front().index);
            }
            outputQueue_.pop();
        }
    }

    static void WriteU16(uint8_t *destination, uint16_t value)
    {
        destination[0] = static_cast<uint8_t>(value >> 8);
        destination[1] = static_cast<uint8_t>(value);
    }

    static void WriteU32(uint8_t *destination, uint32_t value)
    {
        destination[0] = static_cast<uint8_t>(value >> 24);
        destination[1] = static_cast<uint8_t>(value >> 16);
        destination[2] = static_cast<uint8_t>(value >> 8);
        destination[3] = static_cast<uint8_t>(value);
    }

    static void WriteU64(uint8_t *destination, uint64_t value)
    {
        for (int index = 7; index >= 0; --index) {
            destination[7 - index] = static_cast<uint8_t>(value >> (index * 8));
        }
    }

    static void OnCaptureError(OH_AVScreenCapture *, int32_t errorCode, void *userData)
    {
        OH_LOG_Print(LOG_APP, LOG_ERROR, MIRROR_LOG_DOMAIN, MIRROR_LOG_TAG, "capture error %{public}d", errorCode);
        auto *sender = static_cast<MirrorSender *>(userData);
        if (sender != nullptr) {
            sender->running_.store(false);
            sender->queueCondition_.notify_all();
        }
    }

    static void OnCaptureState(OH_AVScreenCapture *capture, OH_AVScreenCaptureStateCode state, void *)
    {
        OH_LOG_Print(LOG_APP, LOG_INFO, MIRROR_LOG_DOMAIN, MIRROR_LOG_TAG, "capture state %{public}d", state);
        if (state == OH_SCREEN_CAPTURE_STATE_STARTED) {
            OH_AVSCREEN_CAPTURE_ErrCode result = OH_AVScreenCapture_SetMaxVideoFrameRate(capture, VIDEO_FPS);
            OH_LOG_Print(LOG_APP, LOG_INFO, MIRROR_LOG_DOMAIN, MIRROR_LOG_TAG,
                "screen capture started max fps=%{public}d result=%{public}d", VIDEO_FPS, result);
        }
    }

    static void OnEncoderError(OH_AVCodec *, int32_t errorCode, void *userData)
    {
        OH_LOG_Print(LOG_APP, LOG_ERROR, MIRROR_LOG_DOMAIN, MIRROR_LOG_TAG, "encoder error %{public}d", errorCode);
        auto *sender = static_cast<MirrorSender *>(userData);
        if (sender != nullptr) {
            sender->running_.store(false);
            sender->queueCondition_.notify_all();
        }
    }

    static void OnStreamChanged(OH_AVCodec *, OH_AVFormat *, void *) {}
    static void OnNeedInputBuffer(OH_AVCodec *, uint32_t, OH_AVBuffer *, void *) {}

    static void OnEncodedBuffer(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *userData)
    {
        auto *sender = static_cast<MirrorSender *>(userData);
        if (sender == nullptr || buffer == nullptr) {
            return;
        }
        sender->BeginOutputCallback();
        if (!sender->acceptingBuffers_.load() || sender->encoder_ == nullptr || !sender->connected_.load()) {
            if (sender->encoder_ != nullptr) {
                OH_VideoEncoder_FreeOutputBuffer(sender->encoder_, index);
            }
            sender->EndOutputCallback();
            return;
        }
        OH_AVCodecBufferAttr attr {};
        if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) {
            if (sender->encoder_ != nullptr) {
                OH_VideoEncoder_FreeOutputBuffer(sender->encoder_, index);
            }
            sender->EndOutputCallback();
            return;
        }
        {
            std::lock_guard<std::mutex> lock(sender->queueMutex_);
            sender->outputQueue_.push({index, buffer, attr});
        }
        sender->queueCondition_.notify_one();
        sender->EndOutputCallback();
    }

    void BeginOutputCallback()
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        ++activeOutputCallbacks_;
    }

    void EndOutputCallback()
    {
        std::lock_guard<std::mutex> lock(callbackMutex_);
        --activeOutputCallbacks_;
        if (activeOutputCallbacks_ == 0) {
            callbackCondition_.notify_all();
        }
    }

    std::atomic<bool> running_ {false};
    std::atomic<bool> connected_ {false};
    std::atomic<bool> acceptingBuffers_ {false};
    std::chrono::steady_clock::time_point streamEpoch_;
    uint64_t lastPresentationTime_ {0};
    std::string host_;
    uint16_t port_ {3211};
    int socketFd_ {-1};
    OH_AVScreenCapture *capture_ {nullptr};
    OH_AVCodec *encoder_ {nullptr};
    std::thread senderThread_;
    std::mutex callbackMutex_;
    std::condition_variable callbackCondition_;
    int activeOutputCallbacks_ {0};
    std::mutex queueMutex_;
    std::condition_variable queueCondition_;
    std::queue<EncodedBuffer> outputQueue_;
};

napi_value Start(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] {};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    size_t hostLength = 0;
    napi_get_value_string_utf8(env, argv[0], nullptr, 0, &hostLength);
    std::vector<char> hostBuffer(hostLength + 1, '\0');
    napi_get_value_string_utf8(env, argv[0], hostBuffer.data(), hostBuffer.size(), &hostLength);
    std::string host(hostBuffer.data(), hostLength);
    int32_t port = 3211;
    napi_get_value_int32(env, argv[1], &port);
    int result = MirrorSender::Instance().Start(host, static_cast<uint16_t>(port));
    napi_value value;
    napi_create_int32(env, result, &value);
    return value;
}

napi_value Stop(napi_env env, napi_callback_info)
{
    int result = MirrorSender::Instance().Stop();
    napi_value value;
    napi_create_int32(env, result, &value);
    return value;
}

napi_value IsRunning(napi_env env, napi_callback_info)
{
    napi_value value;
    napi_get_boolean(env, MirrorSender::Instance().IsRunning(), &value);
    return value;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor descriptors[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, Stop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
    return exports;
}
} // namespace

static napi_module screenMirrorModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "screenmirror",
    .nm_priv = nullptr,
    .reserved = {nullptr},
};

extern "C" __attribute__((constructor)) void RegisterScreenMirrorModule()
{
    napi_module_register(&screenMirrorModule);
}
