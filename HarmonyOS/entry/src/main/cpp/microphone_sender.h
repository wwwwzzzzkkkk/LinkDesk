#pragma once
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <poll.h>
#include <array>
#include <atomic>
#include <algorithm>
#include <chrono>
#include <mutex>
#include <thread>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiocapturer.h>
// Capture is available only after an explicit foreground tablet permission action.
class MicrophoneSender {
public:
    ~MicrophoneSender(){Stop();}
    void Start(){Stop();allowed_=true;worker_=std::thread([this]{Loop();});}
    void Stop(){allowed_=false;{std::lock_guard<std::mutex> lock(mutex_);if(fd_>=0)shutdown(fd_,SHUT_RDWR);}if(worker_.joinable())worker_.join();state_=0;}
    int State()const{return state_.load();}
private:
    static constexpr size_t Capacity=8192;
    std::array<int16_t,Capacity> ring_{};
    std::atomic<uint64_t> head_{0},tail_{0};
    std::atomic<bool> allowed_{false};std::atomic<int> state_{0};
    std::mutex mutex_;int fd_=-1;std::thread worker_;
    OH_AudioCapturer *capturer_=nullptr;
    static void Capture(OH_AudioCapturer *,void *context,void *data,int32_t size){
        auto *s=static_cast<MicrophoneSender *>(context);
        if(!s->allowed_||size<=0||size%2)return;
        size_t count=size/2;uint64_t h=s->head_.load(std::memory_order_relaxed),t=s->tail_.load(std::memory_order_acquire);
        if(count>Capacity||h-t+count>Capacity)return;
        auto *samples=static_cast<const int16_t *>(data);
        for(size_t i=0;i<count;i++)s->ring_[(h+i)%Capacity]=samples[i];
        s->head_.store(h+count,std::memory_order_release);
    }
    bool Send(const void *data,size_t size){auto *p=static_cast<const uint8_t *>(data);while(size&&allowed_){ssize_t n=send(fd_,p,size,MSG_NOSIGNAL);if(n<0&&errno==EINTR)continue;if(n<=0)return false;p+=n;size-=n;}return size==0;}
    bool Create(){
        OH_AudioStreamBuilder *b=nullptr;
        if(OH_AudioStreamBuilder_Create(&b,AUDIOSTREAM_TYPE_CAPTURER)!=AUDIOSTREAM_SUCCESS)return false;
        bool ok=OH_AudioStreamBuilder_SetSamplingRate(b,48000)==AUDIOSTREAM_SUCCESS&&
            OH_AudioStreamBuilder_SetChannelCount(b,1)==AUDIOSTREAM_SUCCESS&&
            OH_AudioStreamBuilder_SetSampleFormat(b,AUDIOSTREAM_SAMPLE_S16LE)==AUDIOSTREAM_SUCCESS&&
            OH_AudioStreamBuilder_SetEncodingType(b,AUDIOSTREAM_ENCODING_TYPE_RAW)==AUDIOSTREAM_SUCCESS&&
            OH_AudioStreamBuilder_SetCapturerInfo(b,AUDIOSTREAM_SOURCE_TYPE_VOICE_COMMUNICATION)==AUDIOSTREAM_SUCCESS&&
            OH_AudioStreamBuilder_SetCapturerReadDataCallback(b,Capture,this)==AUDIOSTREAM_SUCCESS;
        OH_AudioStreamBuilder_SetLatencyMode(b,AUDIOSTREAM_LATENCY_MODE_FAST);
        if(ok)ok=OH_AudioStreamBuilder_GenerateCapturer(b,&capturer_)==AUDIOSTREAM_SUCCESS;
        OH_AudioStreamBuilder_Destroy(b);
        if(ok)ok=OH_AudioCapturer_Start(capturer_)==AUDIOSTREAM_SUCCESS;
        return ok;
    }
    void Session(){
        int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return;
        {std::lock_guard<std::mutex> lock(mutex_);fd_=fd;}
        timeval timeout{2,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        int one=1;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(24835);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        if(!allowed_||connect(fd,reinterpret_cast<sockaddr *>(&address),sizeof(address)))return;
        const uint8_t header[16]={'L','D','M','I',0,0,0xBB,0x80,0,0,0,1,0,0,0,1};
        if(!Send(header,sizeof(header)))return;
        uint8_t request=0;if(recv(fd,&request,1,0)!=1||request!=1)return;
        head_=0;tail_=0;if(!allowed_||!Create()){state_=-1;return;}state_=2;
        auto last=std::chrono::steady_clock::now();
        while(allowed_){
            pollfd event{fd,POLLIN,0};int result=poll(&event,1,0);
            if(result>0&&(event.revents&(POLLIN|POLLHUP|POLLERR|POLLNVAL)))break;
            uint64_t h=head_.load(std::memory_order_acquire),t=tail_.load(std::memory_order_relaxed);
            size_t frames=std::min<uint64_t>(h-t,480);
            auto now=std::chrono::steady_clock::now();
            if(frames||now-last>std::chrono::milliseconds(200)){
                uint32_t bytes=htonl(frames*2);std::array<int16_t,480> pcm{};
                for(size_t i=0;i<frames;i++)pcm[i]=ring_[(t+i)%Capacity];
                tail_.store(t+frames,std::memory_order_release);
                if(!Send(&bytes,4)||(frames&&!Send(pcm.data(),frames*2)))break;
                last=now;
            }else std::this_thread::sleep_for(std::chrono::milliseconds(3));
        }
    }
    void Loop(){
        while(allowed_){state_=1;Session();
            if(capturer_){OH_AudioCapturer_Stop(capturer_);OH_AudioCapturer_Release(capturer_);capturer_=nullptr;}
            {std::lock_guard<std::mutex> lock(mutex_);if(fd_>=0){close(fd_);fd_=-1;}}
            if(allowed_)for(int i=0;i<10&&allowed_;i++)std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }state_=0;
    }
};
