#include <stdint.h>
typedef struct {
    uint64_t cpuBusy, cpuTotal, memoryUsed, memoryTotal, appMemory;
    double appCPUSeconds, wallSeconds;
    int cpuValid, memoryValid, appValid, appCPUValid;
} ACSystemMetrics;
ACSystemMetrics ACReadSystemMetrics(void);
