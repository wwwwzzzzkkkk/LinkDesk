#pragma once
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class CursorReceiver {
public:
    explicit CursorReceiver(uint16_t port=24836):port_(port){}
    ~CursorReceiver(){Stop();}
    void Start(){Stop();active_=true;worker_=std::thread([this]{Loop();});}
    void Stop(){active_=false;{std::lock_guard<std::mutex> lock(socketMutex_);if(fd_>=0)shutdown(fd_,SHUT_RDWR);}if(worker_.joinable())worker_.join();std::lock_guard<std::mutex> lock(mutex_);connected_=false;png_.clear();readPng_.clear();readSequence_=0;}
    // A latest-only mailbox: no queue of obsolete positions on either side.
    std::string Read(){
        std::lock_guard<std::mutex> lock(mutex_);
        bool live=connected_&&std::chrono::steady_clock::now()-received_<std::chrono::milliseconds(250);
        if(!live){if(!shown_)return "";shown_=false;return "{\"visible\":false}";}
        if(readSequence_==sequence_)return "";
        readSequence_=sequence_;shown_=visible_;
        std::string out="{\"visible\":"+std::string(visible_?"true":"false")+",\"x\":"+std::to_string(values_[0]/1000000.0)+",\"y\":"+std::to_string(values_[1]/1000000.0);
        const char *keys[]={"width","height","hotX","hotY"};
        for(int i=0;i<4;i++)out+=",\""+std::string(keys[i])+"\":"+std::to_string(values_[i+2]/1000000.0);
        if(png_!=readPng_){readPng_=png_;out+=",\"image\":\"data:image/png;base64,"+Base64(png_)+"\"";}
        return out+"}";
    }
private:
    uint16_t port_;std::atomic<bool> active_{false};std::thread worker_;
    std::mutex socketMutex_,mutex_;int fd_=-1;bool connected_=false,visible_=false,shown_=false;
    uint32_t sequence_=0,readSequence_=0,values_[6]{};
    std::vector<uint8_t> png_,readPng_;
    std::chrono::steady_clock::time_point received_;
    static uint32_t U32(const uint8_t *p){uint32_t n;memcpy(&n,p,4);return ntohl(n);}
    static std::string Base64(const std::vector<uint8_t>& data){
        static const char alphabet[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";std::string out;out.reserve((data.size()+2)/3*4);
        for(size_t i=0;i<data.size();i+=3){uint32_t n=uint32_t(data[i])<<16;if(i+1<data.size())n|=uint32_t(data[i+1])<<8;if(i+2<data.size())n|=data[i+2];out+=alphabet[n>>18];out+=alphabet[(n>>12)&63];out+=i+1<data.size()?alphabet[(n>>6)&63]:'=';out+=i+2<data.size()?alphabet[n&63]:'=';}return out;
    }
    bool ReadBytes(int fd,void *out,size_t count){auto *p=static_cast<uint8_t*>(out);while(count&&active_){ssize_t n=recv(fd,p,count,0);if(n<0&&errno==EINTR)continue;if(n<=0)return false;p+=n;count-=n;}return count==0;}
    void Loop(){
        while(active_){
            int fd=socket(AF_INET,SOCK_STREAM,0);
            if(fd<0){std::this_thread::sleep_for(std::chrono::milliseconds(100));continue;}
            {std::lock_guard<std::mutex> lock(socketMutex_);fd_=fd;}
            int yes=1;setsockopt(fd,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));timeval timeout{0,250000};
            setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            sockaddr_in address{};address.sin_family=AF_INET;address.sin_port=htons(port_);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
            if(active_&&connect(fd,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0&&send(fd,"LDCUR001",8,MSG_NOSIGNAL)==8){
                while(active_){
                    uint8_t header[48];if(!ReadBytes(fd,header,sizeof(header)))break;
                    uint32_t size=U32(header+4);if(memcmp(header,"LDCP",4)||!size||size>65536||U32(header+12)>1)break;
                    bool valid=true;for(int i=0;i<6;i++)if(U32(header+16+i*4)>1000000)valid=false;if(!valid)break;
                    std::vector<uint8_t> image(size);if(!ReadBytes(fd,image.data(),image.size()))break;
                    const uint8_t signature[]={137,80,78,71,13,10,26,10};if(size<8||memcmp(image.data(),signature,8))break;
                    {std::lock_guard<std::mutex> lock(mutex_);sequence_=U32(header+8);visible_=U32(header+12)!=0;for(int i=0;i<6;i++)values_[i]=U32(header+16+i*4);png_=std::move(image);received_=std::chrono::steady_clock::now();connected_=true;}
                    uint8_t ack[16]={'L','D','C','A'};memcpy(ack+4,header+8,4);memcpy(ack+8,header+40,8);
                    if(send(fd,ack,sizeof(ack),MSG_NOSIGNAL)!=sizeof(ack))break;
                }
            }
            {std::lock_guard<std::mutex> lock(mutex_);connected_=false;readSequence_=0;}
            {std::lock_guard<std::mutex> lock(socketMutex_);close(fd);fd_=-1;}
            if(active_)std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
};
