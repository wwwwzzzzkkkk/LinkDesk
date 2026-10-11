#pragma once
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <array>
#include <atomic>
#include <algorithm>
#include <condition_variable>
#include <cstring>
#include <cmath>
#include <mutex>
#include <thread>
#include <vector>
#include <hilog/log.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>

class AudioReceiver {
public:
    ~AudioReceiver() { Stop(); }
    void Start() { Stop();active_=true;worker_=std::thread([this]{Loop();}); }
    void Stop() {
        active_=false;wake_.notify_all();
        {std::lock_guard<std::mutex> lock(socketMutex_);if(fd_>=0)shutdown(fd_,SHUT_RDWR);}
        if(worker_.joinable())worker_.join();
    }
    int State() const { return state_.load(); }
    uint64_t Played() const { return played_.load(); }
private:
    std::atomic<bool> active_{false};
    std::atomic<int> state_{0};
    std::atomic<uint64_t> played_{0};
    std::atomic<int> peak_{0};
    std::thread worker_;
    std::mutex socketMutex_,waitMutex_;
    std::condition_variable wake_;
    int fd_=-1;
    OH_AudioRenderer *renderer_=nullptr;
    // Single network producer / renderer consumer. Neither callback waits on a lock.
    static constexpr size_t Capacity=4096;
    std::array<int16_t,Capacity*2> ring_{};
    std::atomic<uint64_t> head_{0},tail_{0},flush_{0};
    uint64_t seenFlush_=0;
    bool primed_=false;
    double phase_=0;
    float lastLeft_=0,lastRight_=0,fade_=0;
    std::atomic<uint64_t> underruns_{0},overflows_{0},trims_{0};
    static uint32_t U32(const uint8_t *p) {return uint32_t(p[0])<<24|uint32_t(p[1])<<16|uint32_t(p[2])<<8|p[3];}
    static OH_AudioData_Callback_Result Render(OH_AudioRenderer *,void *context,void *data,int32_t length) {
        auto *self=static_cast<AudioReceiver *>(context);
        if(length<=0)return AUDIO_DATA_CALLBACK_RESULT_VALID;
        auto *out=static_cast<int16_t *>(data);
        uint64_t head=self->head_.load(std::memory_order_acquire),tail=self->tail_.load(std::memory_order_relaxed);
        uint64_t flush=self->flush_.load(std::memory_order_acquire);
        if(flush!=self->seenFlush_){tail=head;self->seenFlush_=flush;self->primed_=false;self->phase_=0;}
        size_t available=head-tail;
        if(available>2880){tail=head-960;available=960;self->primed_=false;self->phase_=0;self->trims_++;}
        if(!self->primed_ && available>=720){self->primed_=true;self->phase_=0;self->fade_=0;}
        double step=1.0+std::clamp((static_cast<double>(available)-720.0)*0.000008,-0.003,0.003);
        bool underrun=false;int peak=0;uint64_t played=0;
        auto sample=[self,&tail](size_t frame,size_t channel)->float {return self->ring_[((tail+frame)%Capacity)*2+channel];};
        for(int i=0;i<length/4;i++) {
            if(self->primed_ && head-tail>=3) {
                float l=sample(0,0)*(1-self->phase_)+sample(1,0)*self->phase_;
                float r=sample(0,1)*(1-self->phase_)+sample(1,1)*self->phase_;
                self->fade_=std::min(1.0f,self->fade_+1.0f/128);
                self->lastLeft_=l*self->fade_;self->lastRight_=r*self->fade_;
                self->phase_+=step;size_t consumed=static_cast<size_t>(self->phase_);self->phase_-=consumed;tail+=consumed;played++;
            } else {
                if(self->primed_){underrun=true;self->primed_=false;}
                self->lastLeft_*=0.98f;self->lastRight_*=0.98f;
            }
            out[i*2]=static_cast<int16_t>(std::clamp(self->lastLeft_,-32767.0f,32767.0f));
            out[i*2+1]=static_cast<int16_t>(std::clamp(self->lastRight_,-32767.0f,32767.0f));
            peak=std::max(peak,std::abs(static_cast<int>(out[i*2])));
        }
        self->tail_.store(tail,std::memory_order_release);
        self->played_+=played;if(underrun)self->underruns_++;
        self->peak_=peak;return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }
    void Clear() {flush_.fetch_add(1,std::memory_order_release);}
    bool Read(void *data,size_t size) {
        auto *p=static_cast<uint8_t *>(data);
        while(size&&active_){ssize_t n=recv(fd_,p,size,0);if(n<0&&errno==EINTR)continue;if(n<=0)return false;p+=n;size-=n;}return size==0;
    }
    bool CreateRenderer() {
        OH_AudioStreamBuilder *builder=nullptr;
        if(OH_AudioStreamBuilder_Create(&builder,AUDIOSTREAM_TYPE_RENDERER)!=AUDIOSTREAM_SUCCESS)return false;
        bool ok=OH_AudioStreamBuilder_SetSamplingRate(builder,48000)==AUDIOSTREAM_SUCCESS &&
            OH_AudioStreamBuilder_SetChannelCount(builder,2)==AUDIOSTREAM_SUCCESS &&
            OH_AudioStreamBuilder_SetSampleFormat(builder,AUDIOSTREAM_SAMPLE_S16LE)==AUDIOSTREAM_SUCCESS &&
            OH_AudioStreamBuilder_SetEncodingType(builder,AUDIOSTREAM_ENCODING_TYPE_RAW)==AUDIOSTREAM_SUCCESS &&
            OH_AudioStreamBuilder_SetRendererInfo(builder,AUDIOSTREAM_USAGE_MUSIC)==AUDIOSTREAM_SUCCESS &&
            OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder,Render,this)==AUDIOSTREAM_SUCCESS;
        OH_AudioStreamBuilder_SetLatencyMode(builder,AUDIOSTREAM_LATENCY_MODE_FAST);
        OH_AudioStreamBuilder_SetFrameSizeInCallback(builder,240);
        if(ok)ok=OH_AudioStreamBuilder_GenerateRenderer(builder,&renderer_)==AUDIOSTREAM_SUCCESS;
        OH_AudioStreamBuilder_Destroy(builder);
        if(ok)ok=OH_AudioRenderer_Start(renderer_)==AUDIOSTREAM_SUCCESS;
        OH_AudioStream_LatencyMode latency=AUDIOSTREAM_LATENCY_MODE_NORMAL;int32_t frames=0;
        if(ok){OH_AudioRenderer_GetLatencyMode(renderer_,&latency);OH_AudioRenderer_GetFrameSizeInCallback(renderer_,&frames);}
        OH_LOG_Print(LOG_APP,LOG_INFO,0x3301,"LinkDesk","AUDIO_RENDERER started=%{public}d latency=%{public}d frames=%{public}d",ok,latency,frames);
        return ok;
    }
    void Session() {
        int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return;
        {std::lock_guard<std::mutex> lock(socketMutex_);fd_=fd;}
        timeval timeout{1,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        int one=1;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(24833);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        if(!active_||connect(fd,reinterpret_cast<sockaddr *>(&address),sizeof(address)))return;
        uint8_t header[16];if(!Read(header,16)||memcmp(header,"LDAU",4)||U32(header+4)!=48000||U32(header+8)!=2||U32(header+12)!=1)return;
        if(!CreateRenderer()){state_=-1;return;}state_=1;unsigned packets=0;
        while(active_) {
            uint8_t packet[8];if(!Read(packet,8))break;
            uint32_t size=U32(packet),route=U32(packet+4);
            if(size>1920||size%4||route>1)break;
            std::vector<uint8_t> pcm(size);if(size&&!Read(pcm.data(),size))break;
            if(!route){Clear();state_=1;continue;}
            state_=2;
            if(size) {
                uint64_t head=head_.load(std::memory_order_relaxed),tail=tail_.load(std::memory_order_acquire);
                size_t frames=size/4;
                if(head-tail+frames>Capacity)overflows_++;
                else {
                    for(size_t i=0;i<frames;i++)for(size_t c=0;c<2;c++) {
                        size_t offset=i*4+c*2;uint16_t bits=pcm[offset]|(uint16_t(pcm[offset+1])<<8);
                        ring_[((head+i)%Capacity)*2+c]=static_cast<int16_t>(bits);
                    }
                    head_.store(head+frames,std::memory_order_release);
                }
                if(++packets%100==0)OH_LOG_Print(LOG_APP,LOG_INFO,0x3301,"LinkDesk","AUDIO_PLAY packets=%{public}u frames=%{public}llu peak=%{public}d underruns=%{public}llu overflows=%{public}llu trims=%{public}llu",packets,static_cast<unsigned long long>(played_.load()),peak_.load(),static_cast<unsigned long long>(underruns_.load()),static_cast<unsigned long long>(overflows_.load()),static_cast<unsigned long long>(trims_.load()));
            }
        }
    }
    void Loop() {
        while(active_) {
            Session();
            if(renderer_){OH_AudioRenderer_Stop(renderer_);OH_AudioRenderer_Release(renderer_);renderer_=nullptr;}
            Clear();{std::lock_guard<std::mutex> lock(socketMutex_);if(fd_>=0){close(fd_);fd_=-1;}}
            state_=0;
            if(active_){std::unique_lock<std::mutex> lock(waitMutex_);wake_.wait_for(lock,std::chrono::milliseconds(500),[this]{return !active_;});}
        }
    }
};
