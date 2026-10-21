#include "../Sources/DirectTransport.h"
#include "../Sources/LevelMeter.h"
#include <math.h>
#include <stdio.h>
#include <mach/mach_time.h>
typedef struct { UInt32 count; AudioBuffer b[2]; } Stereo;
int main(void) {
    float l[2048]={NAN,INFINITY,-INFINITY,.25f},r[2048]={NAN,-INFINITY,INFINITY,-.25f},ol[2048],orr[2048];
    Stereo in={2,{{1,sizeof(l),l},{1,sizeof(r),r}}},out={2,{{1,sizeof(ol),ol},{1,sizeof(orr),orr}}};
    ACDirectTransport *t=ACDirectCreate(); ACDirectSetGain(t,0);
    ACDirectCopy(t,(AudioBufferList*)&in,(AudioBufferList*)&out,0,0);
    unsigned invalid=0; for(unsigned i=0;i<2048;i++) if(ol[i]!=0 || orr[i]!=0) invalid++;
    printf("MUTE_NONFINITE nonzero_or_nan_frames=%u\n",invalid);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    for(unsigned i=0;i<2048;i++) {l[i]=.01f*sinf(i*.1f);r[i]=-l[i];}
    ACDirectSetGain(t,1); ACLevelMeter *m=ACMeterCreate();
    for(unsigned n=128;n<=2048;n*=4) {
        in.b[0].mDataByteSize=in.b[1].mDataByteSize=out.b[0].mDataByteSize=out.b[1].mDataByteSize=n*4;
        uint64_t start=mach_absolute_time();
        for(unsigned iteration=0;iteration<20000;iteration++) {
            ACDirectCopy(t,(AudioBufferList*)&in,(AudioBufferList*)&out,0,0);
            ACMeterObserve(m,(AudioBufferList*)&in,0);
            ACMeterObserve(m,(AudioBufferList*)&out,0);
        }
        double ns=(double)(mach_absolute_time()-start)*tb.numer/tb.denom/20000;
        printf("PCM_BENCH frames=%u average_ns=%.0f deadline_ns=%.0f\n",n,ns,n*1e9/48000);
    }
    ACMeterDestroy(m); ACDirectDestroy(t);
    return invalid ? 1 : 0;
}
