#import "LDAudioSource.h"
#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import <stdlib.h>
#import <math.h>
#import <string.h>
#define CAP 16384
struct LDAudioSource {
    AudioDeviceID input,speaker; AudioDeviceIOProcID inputProc,outputProc;
    AudioStreamBasicDescription inFormat,outFormat;
    Float64 oldRate; UInt32 oldSize;
    _Atomic(uint64_t) head,networkTail,mirrorTail,dropped,outputCalls,outputFrames;
    _Atomic(unsigned) outputBytes,outputPeak;
    _Atomic(float) mirrorGain,networkGain;
    float currentGain;
    _Atomic(bool) enabled,dual,compensateGain;
    _Atomic(unsigned) delayFrames;
    float samples[CAP*2];
    double mirrorPosition; bool mirrorPrimed; unsigned lastDelay;
};
static bool Format(AudioDeviceID d,AudioObjectPropertyScope scope,AudioStreamBasicDescription *f) {
    AudioObjectPropertyAddress a={kAudioDevicePropertyStreamFormat,scope,kAudioObjectPropertyElementMain};UInt32 size=sizeof(*f);
    return !AudioObjectGetPropertyData(d,&a,0,NULL,&size,f)&&f->mFormatID==kAudioFormatLinearPCM&&f->mBitsPerChannel==32&&(f->mFormatFlags&kAudioFormatFlagIsFloat)&&f->mChannelsPerFrame==2;
}
static float Sample(const AudioBufferList *b,unsigned frame,unsigned channel) {
    if(!b||!b->mNumberBuffers)return 0;
    const AudioBuffer *buffer=&b->mBuffers[b->mNumberBuffers>1?channel:0];
    unsigned offset=frame*buffer->mNumberChannels+(b->mNumberBuffers>1?0:channel);
    if(!buffer->mData||(offset+1)*4>buffer->mDataByteSize)return 0;
    float v=((const float *)buffer->mData)[offset];return isfinite(v)?v:0;
}
static OSStatus Input(AudioDeviceID d,const AudioTimeStamp *now,const AudioBufferList *data,const AudioTimeStamp *inputTime,AudioBufferList *out,const AudioTimeStamp *outputTime,void *context) {
    LDAudioSource *s=context;
    if(out)for(unsigned i=0;i<out->mNumberBuffers;i++)if(out->mBuffers[i].mData)memset(out->mBuffers[i].mData,0,out->mBuffers[i].mDataByteSize);
    if(!atomic_load_explicit(&s->enabled,memory_order_relaxed)||!data||!data->mNumberBuffers)return noErr;
    unsigned channels=data->mBuffers[0].mNumberChannels;
    if(!channels)return noErr;
    unsigned count=data->mBuffers[0].mDataByteSize/(4*channels);
    uint64_t head=atomic_load_explicit(&s->head,memory_order_relaxed);
    uint64_t tail=atomic_load_explicit(&s->networkTail,memory_order_acquire);
    if(atomic_load(&s->dual)){uint64_t mirror=atomic_load_explicit(&s->mirrorTail,memory_order_acquire);if(mirror<tail)tail=mirror;}
    if(count>CAP||head-tail+count>CAP){atomic_fetch_add(&s->dropped,count);return noErr;}
    for(unsigned i=0;i<count;i++)for(unsigned c=0;c<2;c++)s->samples[((head+i)%CAP)*2+c]=Sample(data,i,c);
    atomic_store_explicit(&s->head,head+count,memory_order_release);return noErr;
}
static OSStatus Output(AudioDeviceID d,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *inputTime,AudioBufferList *data,const AudioTimeStamp *outputTime,void *context) {
    LDAudioSource *s=context;
    atomic_fetch_add(&s->outputCalls,1);
    if(!data||!data->mNumberBuffers)return noErr;
    atomic_store(&s->outputBytes,data->mBuffers[0].mDataByteSize);
    for(unsigned i=0;i<data->mNumberBuffers;i++)if(data->mBuffers[i].mData)memset(data->mBuffers[i].mData,0,data->mBuffers[i].mDataByteSize);
    uint64_t head=atomic_load_explicit(&s->head,memory_order_acquire);
    if(!atomic_load(&s->enabled)||!atomic_load(&s->dual)) {s->mirrorPrimed=false;atomic_store_explicit(&s->mirrorTail,head,memory_order_release);return noErr;}
    unsigned channels=data->mBuffers[0].mNumberChannels;if(!channels)return noErr;
    unsigned count=data->mBuffers[0].mDataByteSize/(4*channels);
    unsigned delay=atomic_load(&s->delayFrames);
    if(delay!=s->lastDelay){s->mirrorPrimed=false;s->lastDelay=delay;}
    uint64_t tail=atomic_load_explicit(&s->mirrorTail,memory_order_relaxed);
    if(!s->mirrorPrimed){if(head-tail<delay+count)return noErr;s->mirrorPosition=(double)(head-delay-count);s->mirrorPrimed=true;}
    // Resample to the physical device clock. Small rate corrections prevent drift.
    double available=head-s->mirrorPosition;
    double target=delay+count;
    double step=48000.0/s->outFormat.mSampleRate;
    step*=1.0+fmax(-0.003,fmin(0.003,(available-target)*0.000005));
    unsigned peak=0,played=0;
    for(unsigned i=0;i<count;i++) {
        uint64_t frame=(uint64_t)s->mirrorPosition;if(frame+1>=head){s->mirrorPrimed=false;break;}
        double fraction=s->mirrorPosition-frame;
        for(unsigned c=0;c<2;c++){
            float v=s->samples[(frame%CAP)*2+c]*(1-fraction)+s->samples[((frame+1)%CAP)*2+c]*fraction;
            s->currentGain+=(atomic_load_explicit(&s->mirrorGain,memory_order_relaxed)-s->currentGain)/2400.0f;
            v=fmaxf(-1,fminf(1,v*s->currentGain));
            unsigned level=(unsigned)(fabsf(v)*32767);if(level>peak)peak=level;
            AudioBuffer *b=&data->mBuffers[data->mNumberBuffers>1?c:0];
            unsigned index=i*b->mNumberChannels+(data->mNumberBuffers>1?0:c);
            if(b->mData&&(index+1)*4<=b->mDataByteSize)((float *)b->mData)[index]=v;
        }
        s->mirrorPosition+=step;played++;
    }
    atomic_fetch_add(&s->outputFrames,played);atomic_store(&s->outputPeak,peak);
    atomic_store_explicit(&s->mirrorTail,(uint64_t)s->mirrorPosition,memory_order_release);return noErr;
}
LDAudioSource *LDAudioSourceCreate(AudioDeviceID input,AudioDeviceID speaker) {
    LDAudioSource *s=calloc(1,sizeof(*s));if(!s)return NULL;s->input=input;s->speaker=speaker;s->currentGain=1;atomic_store(&s->mirrorGain,1);atomic_store(&s->networkGain,1);atomic_store(&s->compensateGain,true);
    AudioObjectPropertyAddress rate={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 size=sizeof(s->oldRate);
    AudioObjectGetPropertyData(input,&rate,0,NULL,&size,&s->oldRate);Float64 desired=48000;
    OSStatus error=noErr;const char *stage="rate";
    if(s->oldRate!=desired&&(error=AudioObjectSetPropertyData(input,&rate,0,NULL,sizeof(desired),&desired)))goto fail;
    AudioObjectPropertyAddress buffer={kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};size=sizeof(s->oldSize);
    AudioObjectGetPropertyData(input,&buffer,0,NULL,&size,&s->oldSize);UInt32 frames=256;AudioObjectSetPropertyData(input,&buffer,0,NULL,sizeof(frames),&frames);
    stage="format";
    if(!Format(input,kAudioDevicePropertyScopeInput,&s->inFormat)||!Format(speaker,kAudioDevicePropertyScopeOutput,&s->outFormat)||s->inFormat.mSampleRate!=48000)goto fail;
    stage="input create";if((error=AudioDeviceCreateIOProcID(input,Input,s,&s->inputProc)))goto fail;
    stage="input start";if((error=AudioDeviceStart(input,s->inputProc)))goto fail;
    stage="output create";if((error=AudioDeviceCreateIOProcID(speaker,Output,s,&s->outputProc)))goto fail;
    stage="output start";if((error=AudioDeviceStart(speaker,s->outputProc)))goto fail;
    return s;
fail:NSLog(@"AUDIO_DIRECT_ERROR stage=%s code=%d rate=%.0f channels=%u outputRate=%.0f",stage,(int)error,s->inFormat.mSampleRate,s->inFormat.mChannelsPerFrame,s->outFormat.mSampleRate);LDAudioSourceDestroy(s);return NULL;
}
void LDAudioSourceDestroy(LDAudioSource *s) {
    if(!s)return;
    atomic_store(&s->enabled,false);
    if(s->inputProc){AudioDeviceStop(s->input,s->inputProc);AudioDeviceDestroyIOProcID(s->input,s->inputProc);}
    if(s->outputProc){AudioDeviceStop(s->speaker,s->outputProc);AudioDeviceDestroyIOProcID(s->speaker,s->outputProc);}
    AudioObjectPropertyAddress a={kAudioDevicePropertyBufferFrameSize,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 current=0,size=sizeof(current);
    if(s->oldSize&&!AudioObjectGetPropertyData(s->input,&a,0,NULL,&size,&current)&&current==256)AudioObjectSetPropertyData(s->input,&a,0,NULL,sizeof(s->oldSize),&s->oldSize);
    a.mSelector=kAudioDevicePropertyNominalSampleRate;Float64 rate=0;size=sizeof(rate);
    if(s->oldRate&&!AudioObjectGetPropertyData(s->input,&a,0,NULL,&size,&rate)&&rate==48000)AudioObjectSetPropertyData(s->input,&a,0,NULL,sizeof(s->oldRate),&s->oldRate);
    free(s);
}
void LDAudioSourceRoute(LDAudioSource *s,bool enabled,bool dual,double delayMs) {
    if(!s)return;
    atomic_store(&s->delayFrames,(unsigned)(fmax(0,fmin(150,delayMs))*48));
    AudioObjectPropertyAddress a={kAudioDevicePropertyVolumeDecibels,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};Float32 db=0;UInt32 size=sizeof(db);
    float gain=atomic_load(&s->compensateGain)&&AudioObjectGetPropertyData(s->input,&a,0,NULL,&size,&db)==noErr ? fmaxf(1,fminf(16,powf(10,-db/20))) : 1;
    atomic_store(&s->mirrorGain,gain);
    atomic_store(&s->dual,dual);atomic_store(&s->enabled,enabled);
}
unsigned LDAudioSourceRead(LDAudioSource *s,int16_t *pcm,unsigned maxFrames) {
    if(!s)return 0;
    uint64_t head=atomic_load_explicit(&s->head,memory_order_acquire),tail=atomic_load_explicit(&s->networkTail,memory_order_relaxed);
    if(!atomic_load(&s->enabled)){atomic_store_explicit(&s->networkTail,head,memory_order_release);return 0;}
    // Bound transport age, retaining the most recent 20 ms after a blocked sender.
    if(head-tail>3840){tail=head-960;atomic_fetch_add(&s->dropped,1);}
    unsigned n=(unsigned)fmin(maxFrames,head-tail);
    float gain=atomic_load_explicit(&s->networkGain,memory_order_relaxed);
    for(unsigned i=0;i<n;i++)for(unsigned c=0;c<2;c++)pcm[i*2+c]=(int16_t)lrintf(fmaxf(-1,fminf(1,s->samples[((tail+i)%CAP)*2+c]*gain))*32767);
    atomic_store_explicit(&s->networkTail,tail+n,memory_order_release);return n;
}
uint64_t LDAudioSourceDrops(LDAudioSource *s){return s?atomic_load(&s->dropped):0;}

void LDAudioSourceReport(LDAudioSource *s){if(s)NSLog(@"AUDIO_DIRECT_STATS enabled=%d dual=%d gain=%.2f outputCalls=%llu frames=%llu bytes=%u peak=%u dropped=%llu head=%llu tail=%llu",atomic_load(&s->enabled),atomic_load(&s->dual),atomic_load(&s->mirrorGain),(unsigned long long)atomic_load(&s->outputCalls),(unsigned long long)atomic_load(&s->outputFrames),atomic_load(&s->outputBytes),atomic_load(&s->outputPeak),(unsigned long long)atomic_load(&s->dropped),(unsigned long long)atomic_load(&s->head),(unsigned long long)atomic_load(&s->mirrorTail));}

void LDAudioSourceSetGainCompensation(LDAudioSource *s,bool enabled){if(s)atomic_store(&s->compensateGain,enabled);}

void LDAudioSourceSetNetworkGain(LDAudioSource *s,float gain){if(s)atomic_store(&s->networkGain,fmaxf(0,fminf(1,gain)));}
