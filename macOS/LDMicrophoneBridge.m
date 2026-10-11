#import "LDMicrophoneBridge.h"
#import <CoreAudio/CoreAudio.h>
#import <stdatomic.h>
#import <arpa/inet.h>
#import <sys/socket.h>
#import <unistd.h>
#import <math.h>
#import <AudioToolbox/AudioToolbox.h>
#import <string.h>
#define MIC_CAPACITY 8192
// One USB producer and one Core Audio consumer. No network work in the callback.
typedef struct {
    _Atomic(uint64_t) head,tail;
    _Atomic(bool) enabled;
    float samples[MIC_CAPACITY];
    double phase;
    bool primed;
} LDMicRing;
static OSStatus RenderMic(AudioDeviceID device,const AudioTimeStamp *now,const AudioBufferList *in,const AudioTimeStamp *inTime,AudioBufferList *out,const AudioTimeStamp *outTime,void *context) {
    LDMicRing *r=context;
    if(!out)return noErr;
    for(unsigned b=0;b<out->mNumberBuffers;b++)if(out->mBuffers[b].mData)memset(out->mBuffers[b].mData,0,out->mBuffers[b].mDataByteSize);
    uint64_t h=atomic_load_explicit(&r->head,memory_order_acquire),t=atomic_load_explicit(&r->tail,memory_order_relaxed);
    if(!atomic_load(&r->enabled)){r->primed=false;r->phase=0;atomic_store_explicit(&r->tail,h,memory_order_release);return noErr;}
    if(h-t>2880){t=h-960;r->phase=0;r->primed=false;}
    if(!r->primed&&h-t>=720)r->primed=true;
    if(!out->mNumberBuffers||!out->mBuffers[0].mNumberChannels)return noErr;
    unsigned frames=out->mBuffers[0].mDataByteSize/(sizeof(float)*out->mBuffers[0].mNumberChannels);
    double step=1+fmax(-.003,fmin(.003,((double)(h-t)-720)*.000008));
    for(unsigned f=0;f<frames;f++){
        if(!r->primed||h-t<3){r->primed=false;break;}
        float value=r->samples[t%MIC_CAPACITY]*(1-r->phase)+r->samples[(t+1)%MIC_CAPACITY]*r->phase;
        for(unsigned b=0;b<out->mNumberBuffers;b++){
            AudioBuffer *buffer=&out->mBuffers[b];
            for(unsigned c=0;c<buffer->mNumberChannels;c++){
                unsigned i=f*buffer->mNumberChannels+c;
                if(buffer->mData&&(i+1)*sizeof(float)<=buffer->mDataByteSize)((float *)buffer->mData)[i]=value;
            }
        }
        r->phase+=step;unsigned n=(unsigned)r->phase;r->phase-=n;t+=n;
    }
    atomic_store_explicit(&r->tail,t,memory_order_release);return noErr;
}
static AudioDeviceID InputDevice(void){AudioDeviceID d=0;UInt32 size=sizeof(d);AudioObjectPropertyAddress a={kAudioHardwarePropertyDefaultInputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,&d);return d;}
static BOOL SetInput(AudioDeviceID d){if(!d)return NO;AudioObjectPropertyAddress a={kAudioHardwarePropertyDefaultInputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};return AudioObjectSetPropertyData(kAudioObjectSystemObject,&a,0,NULL,sizeof(d),&d)==noErr;}
static uint32_t Read32(const uint8_t *p){return (uint32_t)p[0]<<24|(uint32_t)p[1]<<16|(uint32_t)p[2]<<8|p[3];}
@interface LDMicrophoneBridge (){
    NSLock *_lock; NSString *_message;
    _Atomic(bool) _running,_enabled;
    int _listener,_client;
    dispatch_group_t _worker;
    AudioDeviceID _device,_fallback;
    AudioDeviceIOProcID _proc;
    LDMicRing *_ring;
}
@end
@implementation LDMicrophoneBridge
- (instancetype)init{if((self=[super init])){_lock=[NSLock new];_worker=dispatch_group_create();_listener=_client=-1;_message=@"平板麦克风：关闭";_ring=calloc(1,sizeof(LDMicRing));}return self;}
- (void)dealloc{[self stop];free(_ring);}
- (NSString *)status{[_lock lock];NSString *s=_message;[_lock unlock];return s;}
- (void)message:(NSString *)s{[_lock lock];_message=s;[_lock unlock];}
- (void)restoreInput{if(_device&&InputDevice()==_device)SetInput(_fallback);}
- (void)setEnabled:(BOOL)enabled{
    [_lock lock];atomic_store(&_enabled,enabled);atomic_store(&_ring->enabled,false);
    [self restoreInput];
    if(_client>=0)shutdown(_client,SHUT_RDWR);[_lock unlock];
    [self message:enabled?@"平板麦克风：等待平板允许麦克风":@"平板麦克风：关闭"];
}
- (BOOL)start{
    [self stop];
    AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&size))return NO;
    NSMutableData *data=[NSMutableData dataWithLength:size];if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,data.mutableBytes))return NO;
    AudioDeviceID *ids=data.mutableBytes;_device=0;
    for(unsigned i=0;i<size/sizeof(AudioDeviceID);i++){
        CFStringRef uid=NULL;UInt32 n=sizeof(uid);AudioObjectPropertyAddress u={kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if(!AudioObjectGetPropertyData(ids[i],&u,0,NULL,&n,&uid)){if([(__bridge NSString *)uid isEqual:@"LinkDeskMicrophone_UID"])_device=ids[i];if(uid)CFRelease(uid);}
    }
    if(!_device){[self message:@"平板麦克风：需安装麦克风驱动"];return NO;}
    a.mSelector=kAudioDevicePropertyStreamFormat;a.mScope=kAudioDevicePropertyScopeOutput;AudioStreamBasicDescription f={0};size=sizeof(f);
    if(AudioObjectGetPropertyData(_device,&a,0,NULL,&size,&f)||f.mSampleRate!=48000||f.mBitsPerChannel!=32||f.mChannelsPerFrame!=2||!(f.mFormatFlags&kAudioFormatFlagIsFloat)){[self message:@"平板麦克风：驱动格式不支持"];return NO;}
    _fallback=InputDevice();if(_fallback==_device)_fallback=0;
    if(AudioDeviceCreateIOProcID(_device,RenderMic,_ring,&_proc)||AudioDeviceStart(_device,_proc)){[self stop];[self message:@"平板麦克风：无法启动驱动"];return NO;}
    int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0){[self stop];return NO;}
    int one=1;setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&one,sizeof(one));
    struct sockaddr_in address={0};address.sin_family=AF_INET;address.sin_port=htons(24835);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(fd,(struct sockaddr *)&address,sizeof(address))||listen(fd,2)){close(fd);[self stop];[self message:@"平板麦克风：USB 端口不可用"];return NO;}
    _listener=fd;atomic_store(&_running,true);
    dispatch_group_async(_worker,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self receiveLoop:fd];});return YES;
}
- (BOOL)read:(void *)buffer size:(size_t)size fd:(int)fd{
    uint8_t *p=buffer;while(size&&atomic_load(&_running)){ssize_t n=recv(fd,p,size,0);if(n<0&&errno==EINTR)continue;if(n<=0)return NO;p+=n;size-=n;}return size==0;
}
- (void)receiveLoop:(int)listener{
    while(atomic_load(&_running)){
        int fd=accept(listener,NULL,NULL);if(fd<0){if(errno==EINTR)continue;break;}
        [_lock lock];_client=fd;[_lock unlock];int one=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));struct timeval timeout={2,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
        uint8_t header[16];BOOL valid=[self read:header size:16 fd:fd]&&!memcmp(header,"LDMI",4)&&Read32(header+4)==48000&&Read32(header+8)==1&&Read32(header+12)==1;
        uint8_t request=valid&&atomic_load(&_enabled)?1:0;
        if(valid&&send(fd,&request,1,0)==1&&request){
            while(atomic_load(&_running)&&atomic_load(&_enabled)){
                uint8_t length[4],pcm[1920];if(![self read:length size:4 fd:fd])break;uint32_t bytes=Read32(length);
                if(bytes>sizeof(pcm)||bytes%2)break;
                if(bytes&&![self read:pcm size:bytes fd:fd])break;
                if(!atomic_load(&_enabled))break;
                uint64_t h=atomic_load_explicit(&_ring->head,memory_order_relaxed),t=atomic_load_explicit(&_ring->tail,memory_order_acquire);unsigned frames=bytes/2;
                if(h-t+frames>MIC_CAPACITY)continue;
                for(unsigned i=0;i<frames;i++){int16_t value=(int16_t)((uint16_t)pcm[i*2]|((uint16_t)pcm[i*2+1]<<8));_ring->samples[(h+i)%MIC_CAPACITY]=value/32768.0f;}
                atomic_store_explicit(&_ring->head,h+frames,memory_order_release);
                [_lock lock];
                if(frames&&atomic_load(&_enabled)&&atomic_load(&_running)&&!atomic_exchange(&_ring->enabled,true)){
                    BOOL selected=SetInput(_device);_message=selected?@"平板麦克风：已设为 Mac 输入":@"平板麦克风：请在声音输入中选择 MatePad";
                }
                [_lock unlock];
            }
        }
        [_lock lock];atomic_store(&_ring->enabled,false);[self restoreInput];
        close(fd);_client=-1;[_lock unlock];
        if(atomic_load(&_enabled))[self message:@"平板麦克风：等待平板连接或授权"];
    }
}
- (void)stop{
    atomic_store(&_running,false);atomic_store(&_ring->enabled,false);
    [_lock lock];if(_client>=0)shutdown(_client,SHUT_RDWR);int listener=_listener;_listener=-1;[_lock unlock];
    if(listener>=0){shutdown(listener,SHUT_RDWR);close(listener);}
    dispatch_group_wait(_worker,DISPATCH_TIME_FOREVER);[self restoreInput];
    if(_proc){AudioDeviceStop(_device,_proc);AudioDeviceDestroyIOProcID(_device,_proc);_proc=NULL;}
    _device=0;[self message:@"平板麦克风：关闭"];
}
@end
