#import <CoreAudio/CoreAudio.h>
#import <stdint.h>
#import <stdbool.h>
typedef struct LDAudioSource LDAudioSource;
LDAudioSource *LDAudioSourceCreate(AudioDeviceID input,AudioDeviceID speaker);
void LDAudioSourceDestroy(LDAudioSource *source);
void LDAudioSourceRoute(LDAudioSource *source,bool enabled,bool dual,double delayMs);
unsigned LDAudioSourceRead(LDAudioSource *source,int16_t *pcm,unsigned maxFrames);
uint64_t LDAudioSourceDrops(LDAudioSource *source);

void LDAudioSourceReport(LDAudioSource *source);

void LDAudioSourceSetGainCompensation(LDAudioSource *source,bool enabled);

void LDAudioSourceSetNetworkGain(LDAudioSource *source,float gain);
