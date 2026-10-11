#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <assert.h>
static OSStatus FakeGet(AudioObjectID,const AudioObjectPropertyAddress *,UInt32,const void *,UInt32 *,void *);
static OSStatus FakeSet(AudioObjectID,const AudioObjectPropertyAddress *,UInt32,const void *,UInt32,const void *);
static OSStatus FakeAdd(AudioObjectID,const AudioObjectPropertyAddress *,dispatch_queue_t,AudioObjectPropertyListenerBlock);
static OSStatus FakeRemove(AudioObjectID,const AudioObjectPropertyAddress *,dispatch_queue_t,AudioObjectPropertyListenerBlock);
#define AudioObjectGetPropertyData FakeGet
#define AudioObjectSetPropertyData FakeSet
#define AudioObjectAddPropertyListenerBlock FakeAdd
#define AudioObjectRemovePropertyListenerBlock FakeRemove
#import "../macOS/LDSystemVolume.m"
static struct {Float32 volume;UInt32 mute;} state[2];
static NSMutableDictionary *listeners;
static NSMutableArray *events;
static NSString *key(AudioObjectID d,const AudioObjectPropertyAddress *a){return [NSString stringWithFormat:@"%u/%u",d,a->mSelector];}
static OSStatus FakeGet(AudioObjectID d,const AudioObjectPropertyAddress *a,UInt32 q,const void *qp,UInt32 *size,void *v){
    assert(d==100||d==101);if(*size!=4)return kAudioHardwareBadPropertySizeError;
    if(a->mSelector==kAudioDevicePropertyVolumeScalar)memcpy(v,&state[d-100].volume,4);
    else memcpy(v,&state[d-100].mute,4);return noErr;
}
static OSStatus FakeSet(AudioObjectID d,const AudioObjectPropertyAddress *a,UInt32 q,const void *qp,UInt32 size,const void *v){
    assert(d==100||d==101);if(size!=4)return kAudioHardwareBadPropertySizeError;
    if(a->mSelector==kAudioDevicePropertyVolumeScalar)memcpy(&state[d-100].volume,v,4);
    else memcpy(&state[d-100].mute,v,4);
    AudioObjectPropertyListenerBlock listener=listeners[key(d,a)];AudioObjectPropertyAddress address=*a;
    if(listener)[events addObject:[^{listener(1,&address);} copy]];return noErr;
}
static OSStatus FakeAdd(AudioObjectID d,const AudioObjectPropertyAddress *a,dispatch_queue_t q,AudioObjectPropertyListenerBlock b){listeners[key(d,a)]=[b copy];return noErr;}
static OSStatus FakeRemove(AudioObjectID d,const AudioObjectPropertyAddress *a,dispatch_queue_t q,AudioObjectPropertyListenerBlock b){[listeners removeObjectForKey:key(d,a)];return noErr;}
static void drainOne(void){void(^b)(void)=events.firstObject;[events removeObjectAtIndex:0];b();}
static void drain(void){unsigned count=0;while(events.count){assert(++count<30);drainOne();}}
static void setVolume(AudioDeviceID d,float v){AudioObjectPropertyAddress a=VolumeProp(kAudioDevicePropertyVolumeScalar);FakeSet(d,&a,0,NULL,4,&v);}
int main(){@autoreleasepool{
    listeners=[NSMutableDictionary new];events=[NSMutableArray new];state[0].volume=1;state[1].volume=0.36;
    LDSystemVolume *volume=[LDSystemVolume new];assert([volume startWithControlDevice:100 speaker:101]);[volume setActive:YES];
    assert(fabs(state[0].volume-0.36)<0.00001);
    setVolume(100,0.5);drainOne(); // Hardware notification is still pending.
    setVolume(100,0.6);drain();assert(fabs(state[1].volume-0.6)<0.00001&&fabs(state[0].volume-0.6)<0.00001);
    for(unsigned i=0;i<10;i++)setVolume(100,i/10.0f);drain();assert(fabs(state[1].volume-0.9)<0.00001);
    AudioObjectPropertyAddress mute=VolumeProp(kAudioDevicePropertyMute);UInt32 on=1;FakeSet(100,&mute,0,NULL,4,&on);drain();assert(state[1].mute==1);
    on=0;FakeSet(100,&mute,0,NULL,4,&on);drain();assert(state[1].mute==0);
    setVolume(101,0.7);drain();assert(fabs(state[0].volume-0.7)<0.00001);
    [volume setActive:NO];setVolume(100,0.1);drain();assert(fabs(state[1].volume-0.7)<0.00001);
    [volume setActive:YES];drain();assert(fabs(state[0].volume-0.7)<0.00001);
    [volume stop];assert(listeners.count==0);
    puts("SYSTEM_VOLUME_TEST PASS rapid_keys mute_restore external_change inactive_switch no_feedback_loop");
}}
