#include "DirectTransport.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
struct ACDirectTransport { _Atomic uint64_t frames, mismatches, invalid; _Atomic float gain; };
ACDirectTransport *ACDirectCreate(void) {
    ACDirectTransport *p=calloc(1,sizeof(*p));
    if(p) { atomic_init(&p->frames,0); atomic_init(&p->mismatches,0); atomic_init(&p->invalid,0); atomic_init(&p->gain,1); } return p;
}
void ACDirectDestroy(ACDirectTransport *p) { free(p); }
void ACDirectSetGain(ACDirectTransport *p, float gain) { atomic_store(&p->gain,gain); }
static const AudioBuffer *channel(const AudioBufferList *list, unsigned index, unsigned *offset) {
    for(unsigned i=0;i<list->mNumberBuffers;i++) {
        const AudioBuffer *b=&list->mBuffers[i];
        if(index<b->mNumberChannels) { *offset=index; return b; }
        index-=b->mNumberChannels;
    } return NULL;
}
void ACDirectCopy(ACDirectTransport *p,const AudioBufferList *input,AudioBufferList *output,uint32_t skip,int silent) {
    for(unsigned i=0;i<output->mNumberBuffers;i++) if(output->mBuffers[i].mData) memset(output->mBuffers[i].mData,0,output->mBuffers[i].mDataByteSize);
    unsigned inOffset[2],outOffset[2]; const AudioBuffer *in[2],*out[2]; unsigned n=0;
    for(unsigned c=0;c<2;c++) {
        in[c]=channel(input,skip+c,&inOffset[c]); out[c]=channel(output,c,&outOffset[c]);
        if(!in[c]||!out[c]||!in[c]->mData||!out[c]->mData) { atomic_fetch_add(&p->invalid,1); return; }
        unsigned a=in[c]->mDataByteSize/(4*in[c]->mNumberChannels), b=out[c]->mDataByteSize/(4*out[c]->mNumberChannels);
        if(a!=b || (c && n!=a)) { atomic_fetch_add(&p->invalid,1); return; } n=a;
    }
    uint64_t wrong=0;
    float gain=atomic_load(&p->gain);
    // Output was zeroed above. Multiplying NaN/Inf by zero is not silence.
    if(gain == 0) { atomic_fetch_add(&p->frames,n); return; }
    for(unsigned c=0;c<2;c++) {
        const unsigned char *a=in[c]->mData; unsigned char *b=out[c]->mData;
        for(unsigned i=0;i<n;i++) {
            const void *src=a+4*(i*in[c]->mNumberChannels+inOffset[c]);
            void *dst=b+4*(i*out[c]->mNumberChannels+outOffset[c]);
            memcpy(dst,src,4); if(memcmp(src,dst,4)) wrong++;
            if(gain != 1) { float value; memcpy(&value,src,4); value *= gain; memcpy(dst,&value,4); }
        }
    }
    atomic_fetch_add(&p->frames,n); atomic_fetch_add(&p->mismatches,wrong);
    if(silent) for(unsigned i=0;i<output->mNumberBuffers;i++) if(output->mBuffers[i].mData) memset(output->mBuffers[i].mData,0,output->mBuffers[i].mDataByteSize);
}
ACDirectStats ACDirectGetStats(ACDirectTransport *p) { return (ACDirectStats){atomic_load(&p->frames),atomic_load(&p->mismatches),atomic_load(&p->invalid)}; }
