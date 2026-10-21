#include "../Sources/DirectTransport.h"
#include "../Sources/AudioRing.h"
#include <assert.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
typedef struct { UInt32 count; AudioBuffer b[3]; } List;
int main(void) {
    uint32_t l[4096],r[4096],ol[4096],orr[4096],interleaved[8192];
    for(unsigned i=0;i<4096;i++) { l[i]=0x3e000000u+i*12345u; r[i]=l[i]^0x80000000u; }
    l[0]=0x80000000u; l[1]=0x7fc12345u; l[2]=1; // -0, NaN payload, subnormal must remain unchanged.
    for(unsigned i=0;i<4096;i++){interleaved[i*2]=l[i];interleaved[i*2+1]=r[i];}
    for(unsigned mode=0;mode<4;mode++) {
        ACDirectTransport *q=ACDirectCreate();
        List in={2,{{1,sizeof(l),l},{1,sizeof(r),r}}};
        List out={2,{{1,sizeof(ol),ol},{1,sizeof(orr),orr}}};
        uint32_t mixed[8192];
        if(mode&1) in=(List){1,{{2,sizeof(interleaved),interleaved}}};
        if(mode&2) out=(List){1,{{2,sizeof(mixed),mixed}}};
        ACDirectCopy(q,(AudioBufferList*)&in,(AudioBufferList*)&out,0,0);
        for(unsigned i=0;i<4096;i++) { assert((mode&2?mixed[i*2]:ol[i])==l[i]); assert((mode&2?mixed[i*2+1]:orr[i])==r[i]); }
        ACDirectStats s=ACDirectGetStats(q); assert(s.frames==4096&&s.invalidBlocks==0&&s.mismatches==0);
        ACDirectDestroy(q);
    }
    puts("PASS: direct PCM bit equality, planar/interleaved combinations, -0, NaN payloads and subnormals");
    List in={3,{{1,sizeof(ol),ol},{1,sizeof(l),l},{1,sizeof(r),r}}};
    List out={2,{{1,sizeof(ol),ol},{1,sizeof(orr),orr}}};
    ACDirectTransport *d=ACDirectCreate();
    ACDirectCopy(d,(AudioBufferList*)&in,(AudioBufferList*)&out,1,0);
    assert(!memcmp(l,ol,sizeof(l))&&!memcmp(r,orr,sizeof(r)));
    ACDirectCopy(d,(AudioBufferList*)&in,(AudioBufferList*)&out,1,1);
    for(unsigned i=0;i<4096;i++) assert(ol[i]==0&&orr[i]==0);
    out.b[0].mDataByteSize-=4;
    ACDirectCopy(d,(AudioBufferList*)&in,(AudioBufferList*)&out,1,0);
    assert(ACDirectGetStats(d).invalidBlocks==1);
    ACDirectDestroy(d);
    puts("PASS: skip physical input channels, diagnostic silence after comparison and reject mismatched frames");
    const double rates[]={44100,48000,96000};
    for(unsigned rate=0;rate<3;rate++) {
        float left[4096],right[4096],a[512],b[512];
        for(unsigned i=0;i<4096;i++) {left[i]=(float)(.1*sin(2*M_PI*1000*i/rates[rate])+.1*sin(2*M_PI*18000*i/rates[rate])+.1*sin(2*M_PI*20000*i/rates[rate]));right[i]=-left[i];}
        ACAudioRing *q=ACRingCreate(2048);
        List src={2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
        ACRingAppend(q,(AudioBufferList*)&src,4096);
        for(unsigned block=0;block<8;block++) {
            List dst={2,{{1,sizeof(a),a},{1,sizeof(b),b}}};
            ACRingRender(q,(AudioBufferList*)&dst,512);
            assert(!memcmp(a,left+block*512,sizeof(a))&&!memcmp(b,right+block*512,sizeof(b)));
        }
        assert(ACRingGetStats(q).underruns==0); ACRingDestroy(q);
    }
    puts("PASS: queue null comparison at 44.1/48/96kHz, including 18/20kHz, exact samples from startup");
}
