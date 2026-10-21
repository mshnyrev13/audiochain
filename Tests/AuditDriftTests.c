#include "../Sources/AudioRing.h"
#include <stdio.h>
typedef struct { UInt32 count; AudioBuffer b[2]; } Stereo;
int main(void) {
    float l[1024],r[1024],ol[512],orr[512];
    for(unsigned i=0;i<1024;i++) {l[i]=.01f;r[i]=-.01f;}
    for(int direction=-1;direction<=1;direction++) {
        ACAudioRing *q=ACRingCreate(2048);
        Stereo in={2,{{1,4096,l},{1,4096,r}}},out={2,{{1,2048,ol},{1,2048,orr}}};
        for(unsigned i=0;i<4;i++) ACRingAppend(q,(AudioBufferList*)&in,1024);
        double owed=0;
        for(unsigned tick=0;tick<337500;tick++) {
            owed += 512*(1+direction*.0001);
            unsigned n=(unsigned)owed;owed-=n;
            in.b[0].mDataByteSize=in.b[1].mDataByteSize=n*4;
            ACRingAppend(q,(AudioBufferList*)&in,n);
            ACRingRender(q,(AudioBufferList*)&out,512);
        }
        ACRingStats stats=ACRingGetStats(q);
        printf("SIMULATED_CLOCK_DRIFT seconds=3600 ppm=%d queued_frames=%llu queued_ms=%.3f underruns=%llu dropped=%llu\n",direction*100,(unsigned long long)stats.queued,stats.queued*1000.0/48000,(unsigned long long)stats.underruns,(unsigned long long)stats.dropped);
        ACRingDestroy(q);
    }
    return 0;
}
