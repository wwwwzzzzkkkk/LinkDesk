#import "LDAudioBridge.h"
#import "LDAudioSource.h"
#import "LDSystemVolume.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <arpa/inet.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>
#import <math.h>

static AudioObjectPropertyAddress Prop(AudioObjectPropertySelector s) { return (AudioObjectPropertyAddress){s,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain}; }
static NSString *StringProp(AudioObjectID d, AudioObjectPropertySelector s) {
    CFStringRef value = NULL; UInt32 size = sizeof(value); AudioObjectPropertyAddress a = Prop(s);
    return AudioObjectGetPropertyData(d,&a,0,NULL,&size,&value) == noErr ? CFBridgingRelease(value) : nil;
}
static AudioDeviceID DefaultOutput(void) {
    AudioDeviceID d=0; UInt32 size=sizeof(d); AudioObjectPropertyAddress a=Prop(kAudioHardwarePropertyDefaultOutputDevice);
    AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,&d); return d;
}
static NSArray<NSNumber *> *Devices(void) {
    AudioObjectPropertyAddress a=Prop(kAudioHardwarePropertyDevices); UInt32 size=0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&size)) return @[];
    NSMutableData *data=[NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,data.mutableBytes)) return @[];
    NSMutableArray *result=[NSMutableArray new]; const AudioDeviceID *ids=data.bytes;
    for (NSUInteger i=0;i<size/sizeof(AudioDeviceID);i++) [result addObject:@(ids[i])]; return result;
}
static AudioDeviceID CreateOutput(NSString *uid, NSString *name, NSArray *subdevices, NSString *master) {
    for (NSNumber *n in Devices()) if ([StringProp(n.unsignedIntValue,kAudioDevicePropertyDeviceUID) isEqual:uid]) return n.unsignedIntValue;
    NSDictionary *desc=@{@kAudioAggregateDeviceUIDKey:uid,@kAudioAggregateDeviceNameKey:name,
        @kAudioAggregateDeviceSubDeviceListKey:subdevices,@kAudioAggregateDeviceMainSubDeviceKey:master,
        @kAudioAggregateDeviceIsPrivateKey:@NO,@kAudioAggregateDeviceIsStackedKey:@NO};
    AudioDeviceID device=0; OSStatus result=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)desc,&device);
    NSLog(@"AUDIO_DEVICE name=%@ status=%d id=%u",name,(int)result,(unsigned)device); return result == noErr ? device : 0;
}
static BOOL SendAll(int fd,const void *data,size_t size) {
    const uint8_t *p=data; while(size) { ssize_t n=send(fd,p,size,0); if(n<0&&errno==EINTR)continue; if(n<=0)return NO; p+=n;size-=n; } return YES;
}
@interface LDAudioBridge () {
    NSCondition *_condition;
    LDAudioSource *_source,*_tabletSource,*_dualSource;
    LDSystemVolume *_systemVolume;
    BOOL _nativeVolume;
    double _syncDelay;
    unsigned _diagnosticTick;
    dispatch_group_t _workers;
    BOOL _running, _routed;
    int _listener, _client;
    AudioDeviceID _tablet, _dual, _fallback;
    uint64_t _packetsSent;
    double _disconnectedSince;
    NSString *_failure;
}
@end
@implementation LDAudioBridge
- (instancetype)init { if((self=[super init])) { _condition=[NSCondition new];_syncDelay=20;_systemVolume=[LDSystemVolume new];_workers=dispatch_group_create();_listener=_client=-1; } return self; }
- (NSString *)status { [_condition lock]; NSString *s=_failure ?: (_client < 0 ? @"平板声音未连接" : (_routed ? @"声音正在发送到平板" : @"可在 Mac 声音输出中选择 MatePad")); [_condition unlock]; return s; }
- (BOOL)start {
    [self stop]; NSString *blackhole=nil,*builtIn=nil; AudioDeviceID builtInID=0,blackholeID=0;
    for(NSNumber *n in Devices()) {
        AudioDeviceID d=n.unsignedIntValue; NSString *name=StringProp(d,kAudioObjectPropertyName),*uid=StringProp(d,kAudioDevicePropertyDeviceUID);
        if([uid isEqual:@"LinkDeskTablet_UID"])_tablet=d;
        if([uid isEqual:@"LinkDeskMacVolume_UID"])_dual=d;
        if([name isEqual:@"BlackHole 2ch"]){blackhole=uid;blackholeID=d;}
        AudioObjectPropertyAddress a=Prop(kAudioDevicePropertyTransportType); UInt32 type=0,size=sizeof(type);
        AudioObjectGetPropertyData(d,&a,0,NULL,&size,&type);
        a=Prop(kAudioDevicePropertyStreams);a.mScope=kAudioDevicePropertyScopeOutput;size=0;
        if(type==kAudioDeviceTransportTypeBuiltIn && AudioObjectGetPropertyDataSize(d,&a,0,NULL,&size)==noErr && size>0) { builtIn=uid; builtInID=d; }
    }
    _failure=nil;_nativeVolume=_tablet&&_dual;
    if((!blackhole&&!_nativeVolume)||!builtIn) { _failure=@"声音功能需要 BlackHole 2ch 和 Mac 内置扬声器"; return NO; }
    _fallback=DefaultOutput();
    if(_fallback==_tablet||_fallback==_dual||[StringProp(_fallback,kAudioDevicePropertyDeviceUID) hasPrefix:@"com.zhekuan.linkdesk.audio."])_fallback=builtInID;
    _disconnectedSince=0;
    if(!_nativeVolume) {
        NSDictionary *bh=@{@kAudioSubDeviceUIDKey:blackhole,@kAudioSubDeviceDriftCompensationKey:@YES};
        _tablet=CreateOutput(@"com.zhekuan.linkdesk.audio.tablet",@"MatePad 扬声器（连屏）",@[@{@kAudioSubDeviceUIDKey:blackhole}],blackhole);
        _dual=CreateOutput(@"com.zhekuan.linkdesk.audio.dual",@"Mac 与 MatePad 同时播放",@[bh],blackhole);
    }
    if(!_tablet||!_dual) { _failure=@"无法创建平板声音输出";[self stop];return NO; }
    _tabletSource=LDAudioSourceCreate(_nativeVolume?_tablet:blackholeID,builtInID);
    _dualSource=_nativeVolume?LDAudioSourceCreate(_dual,builtInID):_tabletSource;
    _source=_tabletSource;
    if(!_tabletSource||!_dualSource){_failure=@"无法启动虚拟声卡读取，请停止后重新连接";[self stop];return NO;}
    if(_nativeVolume) {
        // Preserve the previously accepted tablet loudness during driver migration.
        Float32 tabletVolume=0.625f;UInt32 tabletMute=0,size=sizeof(tabletVolume);
        AudioObjectPropertyAddress level={kAudioDevicePropertyVolumeScalar,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};
        if([NSUserDefaults.standardUserDefaults objectForKey:@"LinkDeskTabletVolume"]){
            tabletVolume=[NSUserDefaults.standardUserDefaults floatForKey:@"LinkDeskTabletVolume"];
            tabletMute=[NSUserDefaults.standardUserDefaults boolForKey:@"LinkDeskTabletMuted"];
        } else if(blackholeID) {
            AudioObjectGetPropertyData(blackholeID,&level,0,NULL,&size,&tabletVolume);
            level.mSelector=kAudioDevicePropertyMute;size=sizeof(tabletMute);
            AudioObjectGetPropertyData(blackholeID,&level,0,NULL,&size,&tabletMute);
        }
        level.mSelector=kAudioDevicePropertyVolumeScalar;tabletVolume=MAX(0,MIN(1,tabletVolume));
        AudioObjectSetPropertyData(_tablet,&level,0,NULL,sizeof(tabletVolume),&tabletVolume);
        level.mSelector=kAudioDevicePropertyMute;AudioObjectSetPropertyData(_tablet,&level,0,NULL,sizeof(tabletMute),&tabletMute);
        LDAudioSourceSetGainCompensation(_tabletSource,false);LDAudioSourceSetGainCompensation(_dualSource,false);
        if(![_systemVolume startWithControlDevice:_dual speaker:builtInID]){_failure=@"无法接入 Mac 系统音量";[self stop];return NO;}
    }
    NSLog(@"AUDIO_DIRECT started sampleRate=48000");
    int fd=socket(AF_INET,SOCK_STREAM,0),yes=1;
    if(fd<0){[self stop];return NO;}
    setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    struct sockaddr_in a={0};a.sin_family=AF_INET;a.sin_port=htons(24833);a.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(fd,(struct sockaddr *)&a,sizeof(a))||listen(fd,1)){close(fd);_failure=@"声音端口无法打开";[self stop];return NO;}
    [_condition lock];_listener=fd;_running=YES;[_condition unlock];
    dispatch_group_async(_workers,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        for(;;) {
            [self->_condition lock]; BOOL listening=self->_running; [self->_condition unlock];
            if(!listening)break;
            int client=accept(fd,NULL,NULL); if(client<0)break;
            int one=1,capacity=8192;struct timeval timeout={0,100000};
            setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));setsockopt(client,IPPROTO_TCP,TCP_NODELAY,&one,sizeof(one));
            setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));setsockopt(client,SOL_SOCKET,SO_SNDBUF,&capacity,sizeof(capacity));
            [self->_condition lock];
            if(!self->_running){[self->_condition unlock];close(client);break;}
            self->_client=client;[self->_condition unlock];
            uint32_t header[4]={htonl(0x4c444155),htonl(48000),htonl(2),htonl(1)};
            BOOL ok=SendAll(client,header,sizeof(header));
            NSLog(@"AUDIO_USB connected=%d",ok);
            while(ok) {
                [self->_condition lock]; BOOL running=self->_running; BOOL routed=self->_routed; LDAudioSource *source=self->_source; [self->_condition unlock];
                int16_t pcm[480]; unsigned frames=LDAudioSourceRead(source,pcm,240);
                NSData *packet=frames?[NSData dataWithBytes:pcm length:frames*4]:nil;
                if(!frames)usleep(2000);
                if(!running)break;
                uint32_t h[2]={htonl((uint32_t)packet.length),htonl(routed?1:0)};
                ok=SendAll(client,h,sizeof(h)) && (!packet.length||SendAll(client,packet.bytes,packet.length));
                if(packet.length)self->_packetsSent++;
            }
            [self->_condition lock];close(client);self->_client=-1;[self->_condition unlock];
            NSLog(@"AUDIO_USB disconnected sent=%llu dropped=%llu",self->_packetsSent,(unsigned long long)LDAudioSourceDrops(self->_source));
        }
    });
    [self updateRoute]; return YES;
}
- (void)updateRoute {
    AudioDeviceID d=DefaultOutput();BOOL routed=d&& (d==_tablet||d==_dual);
    [_condition lock]; BOOL connected=_client>=0; [_condition unlock];
    if(routed&&!connected) {
        double now=NSProcessInfo.processInfo.systemUptime;
        if(!_disconnectedSince)_disconnectedSince=now;
        if(now-_disconnectedSince>1.0 && _fallback && DefaultOutput()==d) {
            AudioObjectPropertyAddress a=Prop(kAudioHardwarePropertyDefaultOutputDevice);
            if(AudioObjectSetPropertyData(kAudioObjectSystemObject,&a,0,NULL,sizeof(_fallback),&_fallback)==noErr) { routed=NO;NSLog(@"AUDIO_FALLBACK restored previous output"); }
        }
    } else _disconnectedSince=0;
    [_condition lock];
    if(routed!=_routed) { _routed=routed;[_condition signal];NSLog(@"AUDIO_ROUTE device=%u tablet=%d",(unsigned)d,routed); }
    _source=d==_dual?_dualSource:_tabletSource;
    [_condition unlock];
    [_systemVolume setActive:routed&&d==_dual];
    if(_nativeVolume) {
        AudioObjectPropertyAddress a={kAudioDevicePropertyVolumeDecibels,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};
        Float32 db=0,scalar=0;UInt32 mute=0,size=sizeof(db);
        if(AudioObjectGetPropertyData(_tablet,&a,0,NULL,&size,&db)==noErr){
            a.mSelector=kAudioDevicePropertyMute;size=sizeof(mute);AudioObjectGetPropertyData(_tablet,&a,0,NULL,&size,&mute);
            LDAudioSourceSetNetworkGain(_dualSource,mute?0:powf(10,db/20));
            a.mSelector=kAudioDevicePropertyVolumeScalar;size=sizeof(scalar);
            if(AudioObjectGetPropertyData(_tablet,&a,0,NULL,&size,&scalar)==noErr){
                [NSUserDefaults.standardUserDefaults setFloat:scalar forKey:@"LinkDeskTabletVolume"];
                [NSUserDefaults.standardUserDefaults setBool:mute forKey:@"LinkDeskTabletMuted"];
            }
        }
        LDAudioSourceRoute(_tabletSource,routed&&d==_tablet,false,_syncDelay);
        LDAudioSourceRoute(_dualSource,routed&&d==_dual,true,_syncDelay);
    } else LDAudioSourceRoute(_source,routed,d==_dual,_syncDelay);
    if(++_diagnosticTick%5==0)LDAudioSourceReport(_source);
}
- (void)setSyncDelay:(double)milliseconds { _syncDelay=MAX(0,MIN(150,milliseconds));[self updateRoute]; }
- (void)stop {
    [_condition lock];_running=NO;_routed=NO;
    if(_listener>=0){shutdown(_listener,SHUT_RDWR);close(_listener);_listener=-1;}
    if(_client>=0)shutdown(_client,SHUT_RDWR);
    [_condition broadcast];[_condition unlock];dispatch_group_wait(_workers,DISPATCH_TIME_FOREVER);
    [_systemVolume stop];
    if(_dualSource&&_dualSource!=_tabletSource)LDAudioSourceDestroy(_dualSource);
    if(_tabletSource)LDAudioSourceDestroy(_tabletSource);
    _source=_tabletSource=_dualSource=NULL;
    AudioDeviceID current=DefaultOutput();
    if(current&&(current==_tablet||current==_dual)&&_fallback) {
        AudioObjectPropertyAddress a=Prop(kAudioHardwarePropertyDefaultOutputDevice);
        AudioObjectSetPropertyData(kAudioObjectSystemObject,&a,0,NULL,sizeof(_fallback),&_fallback);
    }
    if(!_nativeVolume){if(_tablet)AudioHardwareDestroyAggregateDevice(_tablet);if(_dual)AudioHardwareDestroyAggregateDevice(_dual);}
    _tablet=_dual=0;
}
@end
