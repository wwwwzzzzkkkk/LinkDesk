#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <assert.h>
#import <math.h>
#import <unistd.h>
static AudioDeviceID device(NSString *uid){CFStringRef u=(__bridge CFStringRef)uid;AudioDeviceID d=0;UInt32 z=sizeof(d);AudioObjectPropertyAddress a={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};assert(!AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(u),&u,&z,&d)&&d);return d;}
static AudioObjectPropertyAddress prop(AudioObjectPropertySelector s){return (AudioObjectPropertyAddress){s,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};}
static float level(AudioDeviceID d){float v=0;UInt32 z=sizeof(v);AudioObjectPropertyAddress a=prop(kAudioDevicePropertyVolumeScalar);assert(!AudioObjectGetPropertyData(d,&a,0,NULL,&z,&v));return v;}
static UInt32 muted(AudioDeviceID d){UInt32 v=0,z=sizeof(v);AudioObjectPropertyAddress a=prop(kAudioDevicePropertyMute);assert(!AudioObjectGetPropertyData(d,&a,0,NULL,&z,&v));return v;}
static void setLevel(AudioDeviceID d,float v){AudioObjectPropertyAddress a=prop(kAudioDevicePropertyVolumeScalar);assert(!AudioObjectSetPropertyData(d,&a,0,NULL,sizeof(v),&v));}
static void setMute(AudioDeviceID d,UInt32 v){AudioObjectPropertyAddress a=prop(kAudioDevicePropertyMute);assert(!AudioObjectSetPropertyData(d,&a,0,NULL,sizeof(v),&v));}
int main(int argc,const char *argv[]){@autoreleasepool{
 AudioDeviceID dual=device(@"LinkDeskMacVolume_UID"),mac=device(@"BuiltInSpeakerDevice"),tablet=device(@"LinkDeskTablet_UID");
 float old=level(mac),tabletLevel=level(tablet);UInt32 oldMute=muted(mac),tabletMute=muted(tablet);
 printf("initial mac=%.6f dual=%.6f tablet=%.6f mute=%u\n",old,level(dual),tabletLevel,oldMute);
 if(argc>1&&!strcmp(argv[1],"--snapshot"))return 0;
 setLevel(dual,0.25);usleep(350000);
 BOOL levelOK=fabsf(level(mac)-0.25)<0.0001f&&fabsf(level(tablet)-tabletLevel)<0.0001f;
 setMute(dual,1);usleep(350000);
 BOOL muteOK=muted(mac)==1&&muted(tablet)==tabletMute;
 setMute(dual,oldMute);setLevel(dual,old);usleep(350000);
 BOOL restored=fabsf(level(mac)-old)<0.0001f&&muted(mac)==oldMute;
 printf("LIVE_VOLUME_TEST level=%s mute=%s restored=%s tablet_unchanged=%s\n",levelOK?"PASS":"FAIL",muteOK?"PASS":"FAIL",restored?"PASS":"FAIL",fabsf(level(tablet)-tabletLevel)<0.0001f?"PASS":"FAIL");
 return levelOK&&muteOK&&restored?0:1;
}}
