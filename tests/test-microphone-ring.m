#import "../macOS/LDMicrophoneBridge.m"
#import <assert.h>
int main(){@autoreleasepool{
 LDMicRing *r=calloc(1,sizeof(LDMicRing));
 struct{UInt32 count;AudioBuffer b;} list={1,{2,256*2*4,NULL}};float out[512];list.b.mData=out;
 for(int i=0;i<2048;i++)r->samples[i]=.25f;atomic_store(&r->head,2048);atomic_store(&r->enabled,true);
 RenderMic(0,NULL,NULL,NULL,(AudioBufferList *)&list,NULL,r);
 for(int i=0;i<512;i++)assert(fabsf(out[i]-.25)<.0001);assert(atomic_load(&r->tail)>0);
 atomic_store(&r->enabled,false);RenderMic(0,NULL,NULL,NULL,(AudioBufferList *)&list,NULL,r);
 for(int i=0;i<512;i++)assert(out[i]==0);assert(atomic_load(&r->tail)==atomic_load(&r->head));
 // Empty and split-channel buffers must stay bounded and silent.
 atomic_store(&r->enabled,true);RenderMic(0,NULL,NULL,NULL,(AudioBufferList *)&list,NULL,r);
 for(int i=0;i<512;i++)assert(out[i]==0);
 free(r);puts("MIC_RING_PASS: stereo samples, disabled silence, flush, underrun");
}}
