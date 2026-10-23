#include "../HarmonyOS/entry/src/main/cpp/microphone_control.h"
#include <cassert>
#include <functional>
#include <iostream>
static void Await(const std::function<bool()> &condition) {
    for(int i=0;i<300&&!condition();i++) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    assert(condition());
}
int main() {
    int listener=socket(AF_INET,SOCK_STREAM,0);assert(listener>=0);
    sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    assert(bind(listener,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))==0);
    socklen_t size=sizeof(addr);getsockname(listener,reinterpret_cast<sockaddr*>(&addr),&size);assert(listen(listener,4)==0);
    std::atomic<bool> running{true}, mac{false}, hold{false}, received{false}, release{false}, reject{false};
    std::atomic<int> queries{0};
    std::thread server([&]{
        while(running){
            int fd=accept(listener,nullptr,nullptr);if(fd<0)break;
            char cmd[8];ssize_t n=recv(fd,cmd,8,MSG_WAITALL);
            if(n==8){
                if(!reject&&!memcmp(cmd,"LDMICON1",8))mac=true;
                if(!reject&&!memcmp(cmd,"LDMICOFF",8))mac=false;
                char response=reject?'E':mac?'1':'0';
                if(!memcmp(cmd,"LDMICGET",8))++queries;
                if(hold.exchange(false)){received=true;while(!release)std::this_thread::sleep_for(std::chrono::milliseconds(1));}
                send(fd,&response,1,0);
            }
            close(fd);
        }
    });
    MicrophoneControl tablet(ntohs(addr.sin_port));tablet.Start();Await([&]{return queries>0;});
    // A Mac choice enables/disables the tablet without a second local action.
    mac=true;Await([&]{return tablet.Requested();});mac=false;Await([&]{return !tablet.Requested();});
    tablet.SetRequested(true);Await([&]{return mac.load();});
    tablet.SetRequested(false);Await([&]{return !mac.load();});
    // Hold an old GET(false), then tap ON. Its reply must not undo the tap.
    hold=true;Await([&]{return received.load();});tablet.SetRequested(true);release=true;
    Await([&]{return mac.load();});assert(tablet.Requested());
    // Invalid/old-peer replies cannot turn a local choice off; retry on recovery.
    reject=true;mac=false;tablet.SetRequested(false);tablet.SetRequested(true);
    std::this_thread::sleep_for(std::chrono::milliseconds(550));assert(tablet.Requested());
    reject=false;Await([&]{return mac.load();});
    tablet.Stop();assert(!tablet.Requested());assert(!mac);
    running=false;shutdown(listener,SHUT_RDWR);close(listener);server.join();
    std::cout<<"MIC_SYNC_PASS: Mac/tablet on-off, stale response, unknown peer, shutdown off\n";
}
