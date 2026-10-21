#include "../Sources/AudioRing.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <math.h>
#include <stddef.h>
typedef struct { UInt32 count; AudioBuffer buffers[2]; } StereoList;
static StereoList list(float *l,float *r,unsigned n) {
    return (StereoList){2, {{1,n*4,l},{1,n*4,r}}};
}
static ACAudioRing *shared;
#define TOTAL 2000000
static void *produce(void *unused) {
    float l[127],r[127];
    for(unsigned start=0;start<TOTAL;) {
        while (ACRingGetStats(shared).queued>8192) sched_yield();
        unsigned n=TOTAL-start<127 ? TOTAL-start : 127;
        for(unsigned i=0;i<n;i++) { l[i]=start+i+1; r[i]=-l[i]; }
        StereoList in=list(l,r,n); ACRingAppend(shared,(AudioBufferList*)&in,n); start+=n;
    }
    return NULL;
}
int main(void) {
    shared=ACRingCreate(0);
    pthread_t thread; pthread_create(&thread,NULL,produce,NULL);
    float l[97],r[97];
    for(unsigned start=0;start<TOTAL;) {
        unsigned n=TOTAL-start<97 ? TOTAL-start : 97;
        while(ACRingGetStats(shared).queued<n) sched_yield();
        StereoList out=list(l,r,n); ACRingRender(shared,(AudioBufferList*)&out,n);
        for(unsigned i=0;i<n;i++) { assert(l[i]==start+i+1); assert(r[i]==-l[i]); }
        start+=n;
    }
    pthread_join(thread,NULL);
    ACRingStats stats=ACRingGetStats(shared);
    assert(stats.written==TOTAL && stats.dropped==0 && stats.underruns==0);
    ACRingDestroy(shared);
    puts("PASS: concurrent producer/consumer, 2 million frames, exact stereo order, ring wrap, no loss");
    // Common-clock delivery with one-block jitter. No rate correction is allowed.
    for(int direction=0;direction<=0;direction++) {
        ACAudioRing *q=ACRingCreate(2048);
        float a[4096],b[4096]; for(unsigned i=0;i<4096;i++) { a[i]=.25f; b[i]=-.25f; }
        StereoList input=list(a,b,4096); ACRingAppend(q,(AudioBufferList*)&input,4096);
        double owed=0;
        for(unsigned tick=0;tick<12000;tick++) {
            owed+=512*(1+direction*.0001);
            if(tick%2) { unsigned n=(unsigned)owed; owed-=n; input=list(a,b,n); ACRingAppend(q,(AudioBufferList*)&input,n); }
            StereoList out=list(l,r,97);
            // Use a 512-frame output buffer.
            float ol[512],oright[512]; out=list(ol,oright,512);
            ACRingRender(q,(AudioBufferList*)&out,512);
            for(unsigned i=0;i<512;i++) { assert(isfinite(ol[i])); assert(fabsf(ol[i]+oright[i])<.000001f); }
        }
        stats=ACRingGetStats(q); assert(stats.underruns==0 && stats.dropped==0 && stats.queued<8192);
        // Starvation is counted once, then silence waits for sufficient prefill.
        for(unsigned i=0;i<30;i++) { float ol[512],orr[512]; StereoList out=list(ol,orr,512); ACRingRender(q,(AudioBufferList*)&out,512); }
        assert(ACRingGetStats(q).underruns==1);
        input=list(a,b,4096); ACRingAppend(q,(AudioBufferList*)&input,4096);
        float ol[512],orr[512]; StereoList out=list(ol,orr,512); ACRingRender(q,(AudioBufferList*)&out,512);
        assert(ol[511]>.24f && ACRingGetStats(q).underruns==1);
        ACRingDestroy(q);
    }
    puts("PASS: common-clock jitter, prefill, starvation and recovery without interpolation");
    // Interleaved stereo and mono duplication.
    for(unsigned channels=1;channels<=2;channels++) {
        ACAudioRing *q=ACRingCreate(0); float data[8]={1,-1,2,-2,3,-3,4,-4};
        StereoList in={1,{{channels,8*4,data},{0,0,NULL}}};
        ACRingAppend(q,(AudioBufferList*)&in,4);
        StereoList out=list(l,r,4); ACRingRender(q,(AudioBufferList*)&out,4);
        for(unsigned i=0;i<4;i++) { assert(l[i]==data[i*channels]); assert(r[i]==data[i*channels+(channels==2)]); }
        ACRingDestroy(q);
    }
    puts("PASS: interleaved stereo and mono");
}
