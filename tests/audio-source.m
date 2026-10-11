#import "../macOS/LDAudioSource.m"
#import <pthread.h>
#import <assert.h>
static _Atomic(bool) done;
static LDAudioSource *source;
static void *Produce(void *unused) {
    float values[64];for(int i=0;i<32;i++){values[i*2]=0.25f;values[i*2+1]=-0.25f;}
    AudioBufferList list={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=sizeof(values),.mData=values}}};
    for(int i=0;i<100000;i++)Input(0,NULL,&list,NULL,NULL,NULL,source);
    atomic_store(&done,true);return NULL;
}
int main(){@autoreleasepool{
    source=calloc(1,sizeof(*source));LDAudioSourceSetNetworkGain(source,1);LDAudioSourceRoute(source,true,false,20);
    pthread_t producer;assert(pthread_create(&producer,NULL,Produce,NULL)==0);
    uint64_t received=0;int16_t pcm[480];
    do {
        unsigned n=LDAudioSourceRead(source,pcm,240);received+=n;
        for(unsigned i=0;i<n;i++){assert(pcm[i*2]==8192);assert(pcm[i*2+1]==-8192);}
    } while(!atomic_load(&done)||atomic_load(&source->head)!=atomic_load(&source->networkTail));
    pthread_join(producer,NULL);assert(received>0);
    LDAudioSourceRoute(source,false,false,20);assert(LDAudioSourceRead(source,pcm,240)==0);
    printf("AUDIO_RING_TEST PASS received=%llu producer_drops=%llu\n",(unsigned long long)received,(unsigned long long)LDAudioSourceDrops(source));free(source);
}}
