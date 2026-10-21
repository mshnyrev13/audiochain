#pragma once
#include <AudioToolbox/AudioToolbox.h>
typedef struct ACLevelMeter ACLevelMeter;
typedef struct { float left, right; } ACPeaks;
ACLevelMeter *ACMeterCreate(void);
void ACMeterDestroy(ACLevelMeter *meter);
void ACMeterObserve(ACLevelMeter *meter, const AudioBufferList *list, unsigned skipChannels);
ACPeaks ACMeterReadReset(ACLevelMeter *meter);
