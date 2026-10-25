#include "../HarmonyOS/entry/src/main/cpp/cursor_receiver.h"
#include <cassert>
#include <functional>
#include <iostream>

static void Wait(const std::function<bool()> &condition){
    auto end=std::chrono::steady_clock::now()+std::chrono::seconds(3);
    while(!condition()){assert(std::chrono::steady_clock::now()<end);std::this_thread::sleep_for(std::chrono::milliseconds(2));}
}
static void Put(std::vector<uint8_t> &p,size_t offset,uint32_t value){value=htonl(value);memcpy(p.data()+offset,&value,4);}
static bool ReadAll(int fd,void *p,size_t left){auto *out=static_cast<uint8_t*>(p);while(left){ssize_t n=recv(fd,out,left,0);if(n<=0)return false;left-=n;out+=n;}return true;}
static std::vector<uint8_t> Packet(uint32_t sequence,uint32_t x){
    std::vector<uint8_t> p(56);memcpy(p.data(),"LDCP",4);Put(p,4,8);Put(p,8,sequence);Put(p,12,1);Put(p,16,x);Put(p,20,500000);Put(p,24,16000);Put(p,28,24000);Put(p,32,1000);Put(p,36,2000);
    const uint8_t signature[]={137,80,78,71,13,10,26,10};memcpy(p.data()+48,signature,8);return p;
}
int main(){
    int listener=socket(AF_INET,SOCK_STREAM,0);assert(listener>=0);sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    assert(bind(listener,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0);assert(listen(listener,1)==0);socklen_t size=sizeof(address);getsockname(listener,reinterpret_cast<sockaddr*>(&address),&size);
    std::atomic<int> phase{0};
    std::thread server([&]{
        int client=accept(listener,nullptr,nullptr);assert(client>=0);timeval timeout{2,0};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
        char hello[8];assert(ReadAll(client,hello,8)&&!memcmp(hello,"LDCUR001",8));
        auto p=Packet(1,250000);
        // TCP is a byte stream: deliberately fragment both header and payload.
        for(size_t offset=0;offset<p.size();){size_t count=std::min<size_t>(3,p.size()-offset);assert(send(client,p.data()+offset,count,0)==static_cast<ssize_t>(count));offset+=count;}
        uint8_t ack[16];assert(ReadAll(client,ack,16)&&!memcmp(ack,"LDCA",4));assert(!memcmp(ack+4,p.data()+8,4));phase=1;
        Wait([&]{return phase==2;});
        for(uint32_t i=2;i<=60;i++){p=Packet(i,600000);assert(send(client,p.data(),p.size(),0)==static_cast<ssize_t>(p.size()));assert(ReadAll(client,ack,16));}phase=3;
        Wait([&]{return phase==4;});p=Packet(61,0);Put(p,4,65537);assert(send(client,p.data(),48,0)==48);
        char byte;assert(recv(client,&byte,1,0)==0);close(client);phase=5;
    });
    CursorReceiver receiver(ntohs(address.sin_port));receiver.Start();std::string snapshot;
    Wait([&]{snapshot=receiver.Read();return snapshot.find("\"x\":0.250000")!=std::string::npos;});
    assert(snapshot.find("data:image/png;base64,iVBORw0KGgo=")!=std::string::npos);assert(receiver.Read().empty());
    Wait([&]{return phase==1;});phase=2;Wait([&]{return phase==3;});snapshot=receiver.Read();assert(snapshot.find("\"x\":0.600000")!=std::string::npos);assert(snapshot.find("image")==std::string::npos);
    std::this_thread::sleep_for(std::chrono::milliseconds(270));assert(receiver.Read()=="{\"visible\":false}");phase=4;Wait([&]{return phase==5;});
    auto start=std::chrono::steady_clock::now();receiver.Stop();assert(std::chrono::steady_clock::now()-start<std::chrono::milliseconds(500));server.join();close(listener);
    std::cout<<"CURSOR_CHANNEL_PASS: fragmented packets, ACK, latest-only positions, shape cache, stale hiding, malformed length, bounded shutdown\n";
}
