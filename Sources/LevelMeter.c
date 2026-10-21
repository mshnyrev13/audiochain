#include "LevelMeter.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
struct ACLevelMeter { _Atomic unsigned peak[2]; };
ACLevelMeter *ACMeterCreate(void) {
    ACLevelMeter *m=calloc(1,sizeof(*m)); if(m) { atomic_init(&m->peak[0],0); atomic_init(&m->peak[1],0); } return m;
}
void ACMeterDestroy(ACLevelMeter *m) { free(m); }
static void publish(_Atomic unsigned *peak,float value) {
    unsigned bits; memcpy(&bits,&value,4);
    unsigned old=atomic_load_explicit(peak,memory_order_relaxed);
    while(bits>old && !atomic_compare_exchange_weak_explicit(peak,&old,bits,memory_order_relaxed,memory_order_relaxed)) {}
}
void ACMeterObserve(ACLevelMeter *m,const AudioBufferList *list,unsigned skip) {
    for(unsigned c=0;c<2;c++) {
        unsigned index=skip+c; const AudioBuffer *buffer=NULL; unsigned offset=0;
        for(unsigned b=0;b<list->mNumberBuffers;b++) {
            const AudioBuffer *candidate=&list->mBuffers[b];
            if(index<candidate->mNumberChannels) { buffer=candidate; offset=index; break; }
            index-=candidate->mNumberChannels;
        }
        // A mono source is shown on both bars; its audio is not modified.
        if(!buffer && c==1 && skip==0 && list->mNumberBuffers==1 && list->mBuffers[0].mNumberChannels==1) { buffer=&list->mBuffers[0]; offset=0; }
        if(!buffer || !buffer->mData || !buffer->mNumberChannels) continue;
        const float *data=buffer->mData; float peak=0;
        unsigned n=buffer->mDataByteSize/(4*buffer->mNumberChannels);
        for(unsigned i=0;i<n;i++) { float value=fabsf(data[i*buffer->mNumberChannels+offset]); if(!isfinite(value)) value=INFINITY; if(value>peak) peak=value; }
        publish(&m->peak[c],peak);
    }
}
ACPeaks ACMeterReadReset(ACLevelMeter *m) {
    unsigned l=atomic_exchange_explicit(&m->peak[0],0,memory_order_relaxed), r=atomic_exchange_explicit(&m->peak[1],0,memory_order_relaxed);
    ACPeaks result; memcpy(&result.left,&l,4); memcpy(&result.right,&r,4); return result;
}
