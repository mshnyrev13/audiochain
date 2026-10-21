#include "../Sources/AudioRing.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
typedef struct { UInt32 count; AudioBuffer b[2]; } Stereo;
int main(int argc, char **argv) {
    int control=argc>1 && argv[1][0]=='c';
    float l[8192]={0},r[8192]={0},ol[2048],orr[2048];
    Stereo in={2,{{1,sizeof(l),l},{1,sizeof(r),r}}},out={2,{{1,sizeof(ol),ol},{1,sizeof(orr),orr}}};
    if(control) {
        for(int quantum=128;quantum<=2048;quantum*=2) for(int ppm=-500;ppm<=500;ppm+=100) {
            ACAudioRing *q=ACRingCreate(2048); assert(ACRingConfigureClockSync(q,48000));
            // Initial backlog emulates the first arriving producer quanta.
            unsigned prefill=(unsigned)fmax(2048,quantum*3)+512;
            in.b[0].mDataByteSize=in.b[1].mDataByteSize=prefill*4;
            ACRingAppend(q,(AudioBufferList*)&in,prefill);
            double owed=0; unsigned min=999999,max=0;
            for(unsigned tick=0;tick<(unsigned)(3600.0*48000/quantum);tick++) {
                // Deterministic alternating +/-32-frame delivery jitter and
                // a clock-direction change at 1800s, with no missing PCM.
                double sign=tick<(unsigned)(1800.0*48000/quantum)?1:-1;
                owed+=quantum*(1+sign*ppm*1e-6)+(tick%2?32:-32);
                unsigned n=(unsigned)owed;owed-=n;
                in.b[0].mDataByteSize=in.b[1].mDataByteSize=n*4;
                ACRingAppend(q,(AudioBufferList*)&in,n);
                out.b[0].mDataByteSize=out.b[1].mDataByteSize=quantum*4;
                ACRingRender(q,(AudioBufferList*)&out,quantum);
                unsigned depth=(unsigned)ACRingGetStats(q).queued;
                if(depth<min)min=depth;if(depth>max)max=depth;
            }
            ACRingStats s=ACRingGetStats(q);
            printf("CLOCK_CONTROL seconds=3600 quantum=%d ppm=%d->%d queue_min=%u max=%u end=%llu correction=%.3f underruns=%llu dropped=%llu\n",quantum,ppm,-ppm,min,max,(unsigned long long)s.queued,ACRingCorrectionPPM(q),(unsigned long long)s.underruns,(unsigned long long)s.dropped);
            assert(s.underruns==0 && s.dropped==0 && max < prefill+1024 && min>256);
            assert(fabs(ACRingCorrectionPPM(q)+ppm)<10);
            ACRingDestroy(q);
        }
        puts("PASS: 55 x simulated hour, all buffer sizes, drift reversal and delivery jitter; controller only (convolution tested separately)");
    } else if(argc==1) {
        for(int rateIndex=0;rateIndex<3;rateIndex++) for(int tone=0;tone<4;tone++) {
            double rate=(double[]){44100,48000,96000}[rateIndex], frequency=(double[]){0,1000,18000,20000}[tone];
            ACAudioRing *q=ACRingCreate(2048); assert(ACRingConfigureClockSync(q,rate));
            uint64_t sample=0; double energy=0; unsigned measured=0; double maxStereo=0;
            clock_t begin=clock();
            for(unsigned tick=0;tick<220;tick++) {
                unsigned n=tick==0?3072:512;
                for(unsigned i=0;i<n;i++,sample++) {l[i]=(float)(.01*sin(2*M_PI*frequency*sample/rate));r[i]=-l[i];}
                in.b[0].mDataByteSize=in.b[1].mDataByteSize=n*4;
                out.b[0].mDataByteSize=out.b[1].mDataByteSize=512*4;
                ACRingAppend(q,(AudioBufferList*)&in,n); ACRingRender(q,(AudioBufferList*)&out,512);
                if(tick>=20) for(unsigned i=0;i<512;i++) {
                    assert(isfinite(ol[i]) && isfinite(orr[i]));
                    energy+=ol[i]*ol[i];measured++;
                    if(fabs(ol[i]+orr[i])>maxStereo)maxStereo=fabs(ol[i]+orr[i]);
                }
            }
            double gain=frequency?20*log10(sqrt(2*energy/measured)/.01):0;
            ACRingStats s=ACRingGetStats(q);
            printf("CLOCK_SIGNAL rate=%.0f tone=%.0f RMS_gain_db=%.8f stereo_error=%.9g cpu_s=%.3f correction_ppm=%.6f\n",rate,frequency,gain,maxStereo,(double)(clock()-begin)/CLOCKS_PER_SEC,ACRingCorrectionPPM(q));
            assert(fabs(gain)<.001 && maxStereo==0 && s.underruns==0 && s.dropped==0);
            if(!frequency)assert(energy==0);
            ACRingDestroy(q);
        }
        puts("PASS: production clock bridge silence/1k/18k/20k, 44.1/48/96k stereo");
    } else {
        for(int rateIndex=0;rateIndex<3;rateIndex++) for(int ppm=-500;ppm<=500;ppm+=1000) {
            double rate=(double[]){44100,48000,96000}[rateIndex], frequency=20000;
            ACAudioRing *q=ACRingCreate(2048); assert(ACRingConfigureClockSync(q,rate));
            uint64_t sample=0;double owed=0,position=0,errorEnergy=0,referenceEnergy=0,dot=0;
            unsigned ticks=(unsigned)(rate*120/512);
            for(unsigned tick=0;tick<ticks;tick++) {
                owed+=512*(1+ppm*1e-6);
                unsigned n=tick==0?3072:(unsigned)owed;
                if(tick==0)owed=0;else owed-=n;
                for(unsigned i=0;i<n;i++,sample++) {l[i]=(float)(.01*sin(2*M_PI*frequency*sample/rate));r[i]=-l[i];}
                in.b[0].mDataByteSize=in.b[1].mDataByteSize=n*4;
                out.b[0].mDataByteSize=out.b[1].mDataByteSize=512*4;
                ACRingAppend(q,(AudioBufferList*)&in,n);ACRingRender(q,(AudioBufferList*)&out,512);
                double step=1+ACRingCorrectionPPM(q)*1e-6;
                for(unsigned i=0;i<512;i++,position+=step) if(tick>20) {
                    double reference=.01*sin(2*M_PI*frequency*position/rate),e=ol[i]-reference;
                    errorEnergy+=e*e;referenceEnergy+=reference*reference;dot+=ol[i]*reference;
                    assert(isfinite(ol[i]) && ol[i]==-orr[i]);
                }
            }
            double snr=10*log10(referenceEnergy/errorEnergy),gain=20*log10(dot/referenceEnergy);
            ACRingStats stats=ACRingGetStats(q);
            printf("CLOCK_FRACTIONAL seconds=120 rate=%.0f drift_ppm=%d correction_ppm=%.3f 20k_gain_db=%.8f error_SNR_db=%.3f underruns=%llu dropped=%llu\n",rate,ppm,ACRingCorrectionPPM(q),gain,snr,(unsigned long long)stats.underruns,(unsigned long long)stats.dropped);fflush(stdout);
            assert(snr>90 && fabs(gain)<.001 && stats.underruns==0 && stats.dropped==0);
            ACRingDestroy(q);
        }
        puts("PASS: complete production convolution, 6 x 120 seconds simulated fractional clock drift, analytic 20k reference");
    }

}
