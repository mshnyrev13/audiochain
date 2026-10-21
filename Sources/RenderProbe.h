#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
typedef struct ACRenderProbe ACRenderProbe;
typedef struct {
    uint64_t frames, buffers, lateBuffers, errors;
    double meanMicroseconds, maxMicroseconds;
    uint64_t totalNanoseconds, exclusiveNanoseconds, invalidMeasurements, inFlight;
    double exclusiveMeanMicroseconds, exclusiveMaxMicroseconds, sampleRate;
} ACRenderProbeStats;
ACRenderProbe *ACRenderProbeCreate(AudioUnit unit);
uint64_t ACRenderProbeFrames(ACRenderProbe *probe);
ACRenderProbeStats ACRenderProbeGetStats(ACRenderProbe *probe);
void ACRenderProbeDestroy(ACRenderProbe *probe);
