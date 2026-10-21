#include "SystemMetrics.h"
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <time.h>
ACSystemMetrics ACReadSystemMetrics(void) {
    ACSystemMetrics r = {0};
    host_t host = mach_host_self();
    host_cpu_load_info_data_t cpu;
    mach_msg_type_number_t n = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(host, HOST_CPU_LOAD_INFO, (host_info_t)&cpu, &n) == KERN_SUCCESS) {
        for (int i=0; i<CPU_STATE_MAX; i++) r.cpuTotal += cpu.cpu_ticks[i];
        r.cpuBusy = r.cpuTotal - cpu.cpu_ticks[CPU_STATE_IDLE]; r.cpuValid = 1;
    }
    vm_statistics64_data_t vm;
    n = HOST_VM_INFO64_COUNT;
    size_t size = sizeof(r.memoryTotal);
    if (sysctlbyname("hw.memsize", &r.memoryTotal, &size, 0, 0) == 0 &&
        host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &n) == KERN_SUCCESS) {
        // App + wired + compressed memory; excludes reusable inactive file cache.
        uint64_t pages = (uint64_t)vm.active_count + vm.inactive_count + vm.wire_count + vm.compressor_page_count;
        pages = pages > vm.purgeable_count ? pages - vm.purgeable_count : pages;
        uint64_t external = vm.external_page_count;
        pages = pages > external ? pages - external : 0;
        r.memoryUsed = pages * vm_page_size; r.memoryValid = 1;
    }
    task_vm_info_data_t tvm; n = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&tvm, &n) == KERN_SUCCESS) {
        r.appMemory = tvm.phys_footprint; r.appValid = 1;
    }
    task_thread_times_info_data_t times; n = TASK_THREAD_TIMES_INFO_COUNT;
    mach_task_basic_info_data_t basic; mach_msg_type_number_t bn = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, (task_info_t)&times, &n) == KERN_SUCCESS &&
        task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic, &bn) == KERN_SUCCESS) {
        r.appCPUSeconds = times.user_time.seconds + times.system_time.seconds + basic.user_time.seconds + basic.system_time.seconds +
            (times.user_time.microseconds + times.system_time.microseconds + basic.user_time.microseconds + basic.system_time.microseconds) / 1e6;
        r.appCPUValid = 1;
    }
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); r.wallSeconds = t.tv_sec + t.tv_nsec / 1e9;
    mach_port_deallocate(mach_task_self(), host);
    return r;
}
