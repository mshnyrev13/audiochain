#include "AudioRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define CAP 131072u
#define TAPS 256u
#define PHASES 2048u
struct ACAudioRing {
    _Atomic uint64_t read, write, written, underruns, dropped;
    float left[CAP], right[CAP];
    uint32_t prefill;
    int primed;
    float *kernel;
    double rate, position, target, filteredError, integral, correction;
    _Atomic double correctionPPM;
};
ACAudioRing *ACRingCreate(uint32_t prefill) {
    ACAudioRing *q = calloc(1, sizeof(*q));
    if (q) { atomic_init(&q->read,0); atomic_init(&q->write,0);
        atomic_init(&q->written,0); atomic_init(&q->underruns,0); atomic_init(&q->dropped,0);
        atomic_init(&q->correctionPPM,0);
        q->prefill = prefill < CAP/2 ? prefill : CAP/2; }
    return q;
}
void ACRingDestroy(ACAudioRing *q) { if(q) free(q->kernel); free(q); }
int ACRingConfigureClockSync(ACAudioRing *q, double rate) {
    if (!q || !isfinite(rate) || rate < 8000 || rate > 384000 || q->kernel) return 0;
    // Blackman-Harris windowed sinc, normalized DC. Coefficient generation
    // and page touching finish before either real-time callback starts.
    q->kernel = calloc((PHASES+1)*TAPS,sizeof(float));
    if (!q->kernel) return 0;
    q->rate = rate;
    const double cutoff = .94;
    for(unsigned p=0;p<=PHASES;p++) {
        double fraction=(double)p/PHASES, sum=0;
        for(unsigned t=0;t<TAPS;t++) {
            double x=(double)t-(TAPS/2-1)-fraction;
            double angle=2*M_PI*((double)t-fraction+.5)/TAPS;
            double window=.35875-.48829*cos(angle)+.14128*cos(2*angle)-.01168*cos(3*angle);
            double value = (fabs(x)<1e-12 ? cutoff : sin(M_PI*cutoff*x)/(M_PI*x))*window;
            q->kernel[p*TAPS+t]=(float)value; sum+=value;
        }
        for(unsigned t=0;t<TAPS;t++) q->kernel[p*TAPS+t]/=(float)sum;
    }
    return 1;
}
double ACRingCorrectionPPM(ACAudioRing *q) {return atomic_load_explicit(&q->correctionPPM,memory_order_relaxed);}

static void renderClocked(ACAudioRing *q, float *left, float *right, uint32_t frames) {
    uint64_t w=atomic_load_explicit(&q->write,memory_order_acquire);
    uint64_t rd=atomic_load_explicit(&q->read,memory_order_relaxed);
    uint32_t threshold=q->prefill > frames*3 ? q->prefill : frames*3;
    if (!q->primed) {
        if(w-rd < threshold+TAPS/2) return;
        // At initial start, retain sample zero and supply zero history. After
        // a genuine underflow history before rd no longer belongs to us.
        q->position=(double)rd+(rd ? TAPS/2 : 0);
        q->target=(double)w-q->position;
        q->filteredError=0; q->integral=0; q->correction=0; q->primed=1;
    }
    double dt=frames/q->rate;
    double error=(double)w-q->position-q->target;
    double alpha=dt/(.5+dt);
    q->filteredError+=alpha*(error-q->filteredError);
    // PI in seconds, independent of callback size. Bound adaptation to
    // +/-2000 ppm, slew <=100 ppm/s. No sample insertion/deletion/queue flush.
    q->integral=fmax(-.0015,fmin(.0015,q->integral+q->filteredError*2e-7*dt));
    double wanted=fmax(-.002,fmin(.002,q->filteredError*4e-6+q->integral));
    q->correction+=fmax(-.0001*dt,fmin(.0001*dt,wanted-q->correction));
    atomic_store_explicit(&q->correctionPPM,q->correction*1e6,memory_order_relaxed);
    double step=1+q->correction;
#ifdef AC_RING_CONTROLLER_SIMULATION
    // Test-only acceleration of hour-long control simulations; signal quality
    // tests compile the complete production convolution below, without this flag.
    if(q->position+(frames-1)*step+TAPS/2 < (double)w) q->position+=frames*step;
    else {atomic_fetch_add_explicit(&q->underruns,1,memory_order_relaxed);q->primed=0;}
#else
    for(unsigned i=0;i<frames;i++) {
        int64_t center=(int64_t)q->position;
        if(center+TAPS/2 >= (int64_t)w) {
            atomic_fetch_add_explicit(&q->underruns,1,memory_order_relaxed);
            q->primed=0; break;
        }
        double phase=(q->position-center)*PHASES;
        unsigned p=(unsigned)phase; float blend=(float)(phase-p);
        const float *a=q->kernel+p*TAPS, *b=a+TAPS;
        float l=0,r=0;
        for(unsigned t=0;t<TAPS;t++) {
            int64_t index=center-(TAPS/2-1)+t;
            if(index<0) continue;
            float k=a[t]+blend*(b[t]-a[t]);
            unsigned j=(unsigned)index&(CAP-1);
            l+=q->left[j]*k; r+=q->right[j]*k;
        }
        left[i]=l; right[i]=r; q->position+=step;
    }
#endif
    uint64_t next=q->position>TAPS/2 ? (uint64_t)q->position-(TAPS/2-1) : 0;
    atomic_store_explicit(&q->read,next,memory_order_release);
}
void ACRingAppend(ACAudioRing *q, const AudioBufferList *list, uint32_t frames) {
    if (!list->mNumberBuffers || !list->mBuffers[0].mData) return;
    const AudioBuffer *a = &list->mBuffers[0];
    unsigned stride = a->mNumberChannels;
    if (!stride) return;
    frames = frames < a->mDataByteSize/(4*stride) ? frames : a->mDataByteSize/(4*stride);
    const float *l = a->mData, *r = l;
    unsigned rstride = stride;
    if (stride > 1) r++;
    else if (list->mNumberBuffers > 1 && list->mBuffers[1].mData) {
        const AudioBuffer *b = &list->mBuffers[1];
        r = b->mData; rstride = b->mNumberChannels;
        if (!rstride) return;
        if (frames > b->mDataByteSize/(4*rstride)) frames = b->mDataByteSize/(4*rstride);
    }
    uint64_t w = atomic_load_explicit(&q->write,memory_order_relaxed);
    uint64_t rd = atomic_load_explicit(&q->read,memory_order_acquire);
    uint32_t room = CAP - (uint32_t)(w-rd), n = frames < room ? frames : room;
    for (uint32_t i=0;i<n;i++) { unsigned j=(w+i)&(CAP-1); q->left[j]=l[i*stride]; q->right[j]=r[i*rstride]; }
    atomic_store_explicit(&q->write,w+n,memory_order_release);
    atomic_fetch_add_explicit(&q->written,n,memory_order_relaxed);
    atomic_fetch_add_explicit(&q->dropped,frames-n,memory_order_relaxed);
}
void ACRingRender(ACAudioRing *q, AudioBufferList *list, uint32_t frames) {
    for (unsigned i=0;i<list->mNumberBuffers;i++) if (list->mBuffers[i].mData) memset(list->mBuffers[i].mData,0,list->mBuffers[i].mDataByteSize);
    if (list->mNumberBuffers < 2 || !list->mBuffers[0].mData || !list->mBuffers[1].mData) return;
    float *l=list->mBuffers[0].mData, *r=list->mBuffers[1].mData;
    if (frames>list->mBuffers[0].mDataByteSize/4) frames=list->mBuffers[0].mDataByteSize/4;
    if (frames>list->mBuffers[1].mDataByteSize/4) frames=list->mBuffers[1].mDataByteSize/4;
    if(q->kernel) {renderClocked(q,l,r,frames); return;}
    uint64_t rd=atomic_load_explicit(&q->read,memory_order_relaxed), w=atomic_load_explicit(&q->write,memory_order_acquire);
    uint32_t target=q->prefill > frames*3 ? q->prefill : frames*3;
    if (!q->primed && q->prefill) {
        if (w-rd < target) return;
        q->primed=1;
    }
    uint32_t i=0;
    for (;i<frames && rd<w;i++,rd++) {
        unsigned a=rd&(CAP-1);
        memcpy(&l[i], &q->left[a], sizeof(float));
        memcpy(&r[i], &q->right[a], sizeof(float));
    }
    if (i<frames) {
        atomic_fetch_add_explicit(&q->underruns,1,memory_order_relaxed);
        q->primed=0;
    }
    atomic_store_explicit(&q->read,rd,memory_order_release);
}
ACRingStats ACRingGetStats(ACAudioRing *q) {
    uint64_t r=atomic_load_explicit(&q->read,memory_order_acquire);
    uint64_t w=atomic_load_explicit(&q->write,memory_order_acquire);
    return (ACRingStats){atomic_load(&q->written),atomic_load(&q->underruns),atomic_load(&q->dropped),w>=r?w-r:0};
}
