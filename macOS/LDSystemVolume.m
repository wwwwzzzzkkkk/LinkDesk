#import "LDSystemVolume.h"
#import <math.h>
static AudioObjectPropertyAddress VolumeProp(AudioObjectPropertySelector selector) {return (AudioObjectPropertyAddress){selector,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};}
static BOOL ReadLevel(AudioDeviceID device,Float32 *volume,UInt32 *mute) {
    AudioObjectPropertyAddress a=VolumeProp(kAudioDevicePropertyVolumeScalar);UInt32 size=sizeof(*volume);
    if(AudioObjectGetPropertyData(device,&a,0,NULL,&size,volume)||!isfinite(*volume))return NO;
    a.mSelector=kAudioDevicePropertyMute;size=sizeof(*mute);
    return AudioObjectGetPropertyData(device,&a,0,NULL,&size,mute)==noErr;
}
static BOOL CopyLevel(AudioDeviceID from,AudioDeviceID to) {
    Float32 volume=0,oldVolume=0;UInt32 mute=0,oldMute=0;
    if(!ReadLevel(from,&volume,&mute)||!ReadLevel(to,&oldVolume,&oldMute))return NO;
    AudioObjectPropertyAddress a=VolumeProp(kAudioDevicePropertyVolumeScalar);BOOL ok=YES;
    if(fabsf(volume-oldVolume)>0.00001f)ok=AudioObjectSetPropertyData(to,&a,0,NULL,sizeof(volume),&volume)==noErr;
    a.mSelector=kAudioDevicePropertyMute;
    if(mute!=oldMute)ok=(AudioObjectSetPropertyData(to,&a,0,NULL,sizeof(mute),&mute)==noErr)&&ok;
    return ok;
}
@implementation LDSystemVolume {
    AudioDeviceID _control,_speaker;
    BOOL _active;
    Float32 _lastHardwareVolume; UInt32 _lastHardwareMute;
    AudioObjectPropertyListenerBlock _controlListener,_speakerListener;
}
- (BOOL)startWithControlDevice:(AudioDeviceID)control speaker:(AudioDeviceID)speaker {
    [self stop];_control=control;_speaker=speaker;
    if(!CopyLevel(speaker,control)){_control=_speaker=0;return NO;}
    ReadLevel(speaker,&_lastHardwareVolume,&_lastHardwareMute);
    __weak LDSystemVolume *weakSelf=self;
    _controlListener=^(UInt32 count,const AudioObjectPropertyAddress *addresses){
        LDSystemVolume *s=weakSelf;if(s&&s->_active){
            if(!CopyLevel(s->_control,s->_speaker))NSLog(@"VOLUME_SYNC control-to-Mac failed");
            ReadLevel(s->_speaker,&s->_lastHardwareVolume,&s->_lastHardwareMute);
        }
    };
    _speakerListener=^(UInt32 count,const AudioObjectPropertyAddress *addresses){
        LDSystemVolume *s=weakSelf;if(s&&s->_active){
            Float32 volume=0;UInt32 mute=0;if(!ReadLevel(s->_speaker,&volume,&mute))return;
            // Ignore our own delayed notification, which must not undo a newer key press.
            if(fabsf(volume-s->_lastHardwareVolume)<=0.00001f&&mute==s->_lastHardwareMute)return;
            s->_lastHardwareVolume=volume;s->_lastHardwareMute=mute;
            if(!CopyLevel(s->_speaker,s->_control))NSLog(@"VOLUME_SYNC Mac-to-control failed");
        }
    };
    for(NSUInteger i=0;i<2;i++) {
        AudioObjectPropertyAddress a=VolumeProp(i?kAudioDevicePropertyMute:kAudioDevicePropertyVolumeScalar);
        if(AudioObjectAddPropertyListenerBlock(control,&a,dispatch_get_main_queue(),_controlListener)||
           AudioObjectAddPropertyListenerBlock(speaker,&a,dispatch_get_main_queue(),_speakerListener)){[self stop];return NO;}
    }
    return YES;
}
- (void)setActive:(BOOL)active {
    if(active==_active)return;
    if(active&&_control&&_speaker){CopyLevel(_speaker,_control);ReadLevel(_speaker,&_lastHardwareVolume,&_lastHardwareMute);}
    _active=active;
}
- (void)stop {
    _active=NO;
    for(NSUInteger i=0;i<2;i++) {
        AudioObjectPropertyAddress a=VolumeProp(i?kAudioDevicePropertyMute:kAudioDevicePropertyVolumeScalar);
        if(_control&&_controlListener)AudioObjectRemovePropertyListenerBlock(_control,&a,dispatch_get_main_queue(),_controlListener);
        if(_speaker&&_speakerListener)AudioObjectRemovePropertyListenerBlock(_speaker,&a,dispatch_get_main_queue(),_speakerListener);
    }
    _control=_speaker=0;_controlListener=_speakerListener=nil;
}
@end
