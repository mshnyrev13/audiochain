#include "RenderProbe.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <mach/mach_time.h>
struct ACRenderProbe {
    AudioUnit unit;
    _Atomic uint64_t frames, buffers, totalNS, maxNS, exclusiveNS, maxExclusiveNS, invalid, active, late, errors;
    double nanosecondsPerTick, sampleRate;
};
typedef struct { ACRenderProbe *probe; uint64_t start, children; } ACProbeFrame;
static _Thread_local struct { ACProbeFrame stack[256]; unsigned depth, overflow; } nesting;
static void maximum(_Atomic uint64_t *target,uint64_t value) {
    uint64_t old=atomic_load_explicit(target,memory_order_relaxed);
    while(value>old && !atomic_compare_exchange_weak_explicit(target,&old,value,memory_order_relaxed,memory_order_relaxed)) {}
}
static OSStatus observe(void *context, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    if(bus != 0) return noErr;
    ACRenderProbe *p=context;
    if(*flags & kAudioUnitRenderAction_PostRenderError) atomic_fetch_add_explicit(&p->errors,1,memory_order_relaxed);
    if(*flags & kAudioUnitRenderAction_PreRender) {
        atomic_fetch_add_explicit(&p->active,1,memory_order_relaxed);
        if(nesting.depth>=256 || nesting.overflow) {
            nesting.overflow++;atomic_fetch_add_explicit(&p->invalid,1,memory_order_relaxed);
            for(unsigned i=0;i<nesting.depth;i++) atomic_fetch_add_explicit(&nesting.stack[i].probe->invalid,1,memory_order_relaxed);
        }
        else {nesting.stack[nesting.depth++]=(ACProbeFrame){p,mach_absolute_time(),0};}
    }
    if(*flags & (kAudioUnitRenderAction_PostRender | kAudioUnitRenderAction_PostRenderError)) {
        uint64_t active=atomic_load_explicit(&p->active,memory_order_relaxed);
        while(active && !atomic_compare_exchange_weak_explicit(&p->active,&active,active-1,memory_order_relaxed,memory_order_relaxed)) {}
        if(nesting.overflow) {nesting.overflow--;return noErr;}
        unsigned position=nesting.depth;
        while(position && nesting.stack[position-1].probe!=p) position--;
        if(!position) {
            atomic_fetch_add_explicit(&p->invalid,1,memory_order_relaxed);
            while(nesting.depth) {atomic_fetch_add_explicit(&nesting.stack[--nesting.depth].probe->invalid,1,memory_order_relaxed);}
            return noErr;
        }
        unsigned index=position-1;
        ACProbeFrame frame=nesting.stack[index];
        // Multiple clients may observe the same AU. Their pre/post callbacks
        // can overlap rather than nest; do not mistake another observer for
        // upstream DSP or discard the render heartbeat.
        for(unsigned i=index+1;i<nesting.depth;i++) {
            if(nesting.stack[i].probe->unit!=p->unit) atomic_fetch_add_explicit(&p->invalid,1,memory_order_relaxed);
            if(nesting.stack[i].children>frame.children) frame.children=nesting.stack[i].children;
        }
        int top=(index==nesting.depth-1);
        for(unsigned i=index+1;i<nesting.depth;i++) nesting.stack[i-1]=nesting.stack[i];
        nesting.depth--;
        uint64_t ticks=mach_absolute_time()-frame.start;
        if(top && nesting.depth && nesting.stack[nesting.depth-1].probe->unit!=p->unit) nesting.stack[nesting.depth-1].children+=ticks;
        uint64_t ns=(uint64_t)(ticks*p->nanosecondsPerTick);
        uint64_t exclusive=(uint64_t)((ticks>frame.children ? ticks-frame.children:0)*p->nanosecondsPerTick);
        atomic_fetch_add_explicit(&p->frames,frames,memory_order_relaxed);
        atomic_fetch_add_explicit(&p->buffers,1,memory_order_relaxed);
        atomic_fetch_add_explicit(&p->totalNS,ns,memory_order_relaxed);
        atomic_fetch_add_explicit(&p->exclusiveNS,exclusive,memory_order_relaxed);
        maximum(&p->maxNS,ns);maximum(&p->maxExclusiveNS,exclusive);
        if(p->sampleRate>0 && ns>frames*1e9/p->sampleRate) atomic_fetch_add_explicit(&p->late,1,memory_order_relaxed);
    }
    return noErr;
}
ACRenderProbe *ACRenderProbeCreate(AudioUnit unit) {
    ACRenderProbe *p=calloc(1,sizeof(*p)); if(!p) return NULL;
    p->unit=unit;
    atomic_init(&p->frames,0); atomic_init(&p->buffers,0); atomic_init(&p->totalNS,0);
    atomic_init(&p->maxNS,0); atomic_init(&p->late,0); atomic_init(&p->errors,0);
    atomic_init(&p->exclusiveNS,0);atomic_init(&p->maxExclusiveNS,0);atomic_init(&p->invalid,0);atomic_init(&p->active,0);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb); p->nanosecondsPerTick=(double)tb.numer/tb.denom;
    UInt32 size=sizeof(p->sampleRate);
    AudioUnitGetProperty(unit,kAudioUnitProperty_SampleRate,kAudioUnitScope_Output,0,&p->sampleRate,&size);
    if(AudioUnitAddRenderNotify(unit,observe,p)!=noErr) { free(p); return NULL; }
    return p;
}
uint64_t ACRenderProbeFrames(ACRenderProbe *p) { return atomic_load_explicit(&p->frames,memory_order_relaxed); }
ACRenderProbeStats ACRenderProbeGetStats(ACRenderProbe *p) {
    uint64_t n=atomic_load(&p->buffers);
    uint64_t total=atomic_load(&p->totalNS),exclusive=atomic_load(&p->exclusiveNS);
    return (ACRenderProbeStats){atomic_load(&p->frames),n,atomic_load(&p->late),atomic_load(&p->errors),n?(double)total/n/1000:0,(double)atomic_load(&p->maxNS)/1000,total,exclusive,atomic_load(&p->invalid),atomic_load(&p->active),n?(double)exclusive/n/1000:0,(double)atomic_load(&p->maxExclusiveNS)/1000,p->sampleRate};
}
void ACRenderProbeDestroy(ACRenderProbe *p) { if(p) { AudioUnitRemoveRenderNotify(p->unit,observe,p); free(p); } }
