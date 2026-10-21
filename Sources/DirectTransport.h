#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <stdint.h>
typedef struct ACDirectTransport ACDirectTransport;
typedef struct { uint64_t frames, mismatches, invalidBlocks; } ACDirectStats;
ACDirectTransport *ACDirectCreate(void);
void ACDirectDestroy(ACDirectTransport *transport);
void ACDirectSetGain(ACDirectTransport *transport, float gain);
void ACDirectCopy(ACDirectTransport *transport, const AudioBufferList *input, AudioBufferList *output, uint32_t skipInputChannels, int silenceAfterCheck);
ACDirectStats ACDirectGetStats(ACDirectTransport *transport);
