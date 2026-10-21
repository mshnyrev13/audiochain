#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
typedef struct ACAudioRing ACAudioRing;
typedef struct { uint64_t written, underruns, dropped, queued; } ACRingStats;
ACAudioRing *ACRingCreate(uint32_t prefill);
void ACRingDestroy(ACAudioRing *ring);
void ACRingAppend(ACAudioRing *ring, const AudioBufferList *list, uint32_t frames);
void ACRingRender(ACAudioRing *ring, AudioBufferList *list, uint32_t frames);
ACRingStats ACRingGetStats(ACAudioRing *ring);
// Configure only while both producer and consumer are stopped. Near-unity
// asynchronous clock bridge; nominal rate changes use Apple Mastering SRC.
int ACRingConfigureClockSync(ACAudioRing *ring, double sampleRate);
double ACRingCorrectionPPM(ACAudioRing *ring);
