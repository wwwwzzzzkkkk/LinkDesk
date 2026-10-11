#include <assert.h>
#include <math.h>
#include <stdio.h>
#define kDriver_Name "LinkDeskTest"
#define kDevice_Name "LinkDesk test endpoint"
#include "../macOS/AudioDriver/LinkDeskAudio.c"
static void volume(float v) {
    AudioObjectPropertyAddress p={kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain},changed[2];UInt32 count=0,size=sizeof(v);float actual=-1;
    Boolean writable=false;assert(BlackHole_IsControlPropertySettable(gAudioServerPlugInDriverRef,kObjectID_Volume_Output_Master,0,&p,&writable)==noErr&&writable);
    assert(BlackHole_SetControlPropertyData(gAudioServerPlugInDriverRef,kObjectID_Volume_Output_Master,0,&p,0,NULL,sizeof(v),&v,&count,changed)==noErr);
    assert(BlackHole_GetControlPropertyData(gAudioServerPlugInDriverRef,kObjectID_Volume_Output_Master,0,&p,0,NULL,size,&size,&actual)==noErr);
    assert(fabsf(v-actual)<0.00001f);
}
static void mute(UInt32 m) {
    AudioObjectPropertyAddress p={kAudioBooleanControlPropertyValue,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain},changed[2];UInt32 count=0,actual=9,size=sizeof(actual);
    assert(BlackHole_SetControlPropertyData(gAudioServerPlugInDriverRef,kObjectID_Mute_Output_Master,0,&p,0,NULL,sizeof(m),&m,&count,changed)==noErr);
    assert(BlackHole_GetControlPropertyData(gAudioServerPlugInDriverRef,kObjectID_Mute_Output_Master,0,&p,0,NULL,size,&size,&actual)==noErr&&actual==m);
}
static void audio(bool muted,float level) {
    float input[512],output[512];for(unsigned i=0;i<512;i++)input[i]=(i&1)?-0.2f:0.3f;
    AudioServerPlugInIOCycleInfo cycle={0};cycle.mCurrentTime.mSampleTime=900;cycle.mOutputTime.mSampleTime=1000;cycle.mInputTime.mSampleTime=1000;
    assert(BlackHole_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Output,1,kAudioServerPlugInIOOperationWriteMix,256,&cycle,input,NULL)==noErr);
    assert(BlackHole_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Input,1,kAudioServerPlugInIOOperationReadInput,256,&cycle,output,NULL)==noErr);
    for(unsigned i=0;i<512;i++) {
        float expected=LINKDESK_CONTROL_ONLY?input[i]:(muted?0:input[i]*volume_from_scalar(level));
        assert(fabsf(expected-output[i])<0.000001f);
    }
}
int main(void) {
    assert(BlackHole_Create(NULL,kAudioServerPlugInTypeUUID)==gAudioServerPlugInDriverRef);
    assert(BlackHole_StartIO(gAudioServerPlugInDriverRef,kObjectID_Device,1)==noErr);
    for(unsigned i=0;i<=10;i++){float v=i/10.0f;volume(v);mute(0);audio(false,v);mute(1);audio(true,v);}
    assert(BlackHole_StopIO(gAudioServerPlugInDriverRef,kObjectID_Device,1)==noErr);
    printf("DRIVER_TEST PASS control_only=%d volume_and_mute_roundtrip=OK pcm_independence=OK\n",LINKDESK_CONTROL_ONLY);
}
