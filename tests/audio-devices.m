#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
static NSString *str(AudioObjectID d,AudioObjectPropertySelector s){AudioObjectPropertyAddress a={s,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};CFStringRef v=NULL;UInt32 z=sizeof(v);return AudioObjectGetPropertyData(d,&a,0,NULL,&z,&v)==noErr?CFBridgingRelease(v):@"";}
int main(int argc,const char *argv[]){@autoreleasepool{
 AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 z=0;AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&z);NSMutableData *b=[NSMutableData dataWithLength:z];AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&z,b.mutableBytes);AudioDeviceID *ds=b.mutableBytes;
 AudioObjectPropertyAddress def={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};AudioDeviceID current=0;UInt32 n=sizeof(current);AudioObjectGetPropertyData(kAudioObjectSystemObject,&def,0,NULL,&n,&current);
 BOOL found=NO;
 for(unsigned i=0;i<z/sizeof(AudioDeviceID);i++){
  NSString *uid=str(ds[i],kAudioDevicePropertyDeviceUID);NSString *name=str(ds[i],kAudioObjectPropertyName);
  if(argc==3&&!strcmp(argv[1],"--set")&&[uid isEqual:@(argv[2])]){OSStatus s=AudioObjectSetPropertyData(kAudioObjectSystemObject,&def,0,NULL,sizeof(ds[i]),&ds[i]);printf("set status=%d\n",(int)s);return s?1:0;}
  if(argc==2&&!strcmp(argv[1],"--default")){if(ds[i]==current){puts(uid.UTF8String);found=YES;}}
  else if(argc==1) {printf("%s %u %s | %s\n",ds[i]==current?"*":" ",ds[i],name.UTF8String,uid.UTF8String);}
 }
 return argc==3?2:(argc==2&&!found?2:0);
}}
