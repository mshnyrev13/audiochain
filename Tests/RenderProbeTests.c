#include "../Sources/RenderProbe.c"
#include <assert.h>
#include <unistd.h>
#include <pthread.h>
#include <stdio.h>
static void initProbe(ACRenderProbe *p,uintptr_t id) {
    *p=(ACRenderProbe){0};p->unit=(AudioUnit)id;p->sampleRate=48000;
    mach_timebase_info_data_t tb;mach_timebase_info(&tb);p->nanosecondsPerTick=(double)tb.numer/tb.denom;
}
static void pre(ACRenderProbe *p) {AudioUnitRenderActionFlags f=kAudioUnitRenderAction_PreRender;observe(p,&f,NULL,0,512,NULL);}
static void post(ACRenderProbe *p) {AudioUnitRenderActionFlags f=kAudioUnitRenderAction_PostRender;observe(p,&f,NULL,0,512,NULL);}
static ACRenderProbe shared;
static void *worker(void *v) {for(int i=0;i<10000;i++) {pre(&shared);post(&shared);}return NULL;}
int main(void) {
    ACRenderProbe parent,child,duplicate;initProbe(&parent,1);initProbe(&child,2);initProbe(&duplicate,1);
    pre(&parent);usleep(1000);pre(&child);usleep(4000);post(&child);usleep(1000);post(&parent);
    ACRenderProbeStats p=ACRenderProbeGetStats(&parent),c=ACRenderProbeGetStats(&child);
    assert(p.frames==512 && c.frames==512 && p.invalidMeasurements==0);
    assert(p.meanMicroseconds>c.meanMicroseconds && p.exclusiveMeanMicroseconds<p.meanMicroseconds-3000);
    pre(&parent);pre(&duplicate);pre(&child);post(&child);post(&parent);post(&duplicate);
    assert(ACRenderProbeGetStats(&parent).buffers==2 && ACRenderProbeGetStats(&duplicate).buffers==1);
    assert(ACRenderProbeGetStats(&parent).invalidMeasurements==0 && ACRenderProbeGetStats(&duplicate).invalidMeasurements==0);
    initProbe(&shared,3);pthread_t threads[4];
    for(int i=0;i<4;i++) pthread_create(&threads[i],NULL,worker,NULL);
    for(int i=0;i<4;i++) pthread_join(threads[i],NULL);
    assert(ACRenderProbeGetStats(&shared).buffers==40000 && ACRenderProbeGetStats(&shared).invalidMeasurements==0 && ACRenderProbeGetStats(&shared).inFlight==0);
    ACRenderProbe depth[260];
    for(int i=0;i<260;i++) {initProbe(&depth[i],i+100);pre(&depth[i]);}
    for(int i=259;i>=0;i--) post(&depth[i]);
    assert(ACRenderProbeGetStats(&depth[0]).invalidMeasurements>0);
    pre(&child);post(&child);assert(ACRenderProbeGetStats(&child).buffers==3);
    AudioUnitRenderActionFlags error=kAudioUnitRenderAction_PostRenderError;
    observe(&child,&error,NULL,0,512,NULL);
    assert(ACRenderProbeGetStats(&child).errors==1 && ACRenderProbeGetStats(&child).invalidMeasurements==1);
    pre(&child);assert(ACRenderProbeGetStats(&child).inFlight==1);post(&child);assert(ACRenderProbeGetStats(&child).inFlight==0);
    printf("PASS: nested exclusive time, overlapping observers of same AU, 4-thread atomic counters, bounded overflow recovery; callback has no allocation/locks\n");
    return 0;
}
