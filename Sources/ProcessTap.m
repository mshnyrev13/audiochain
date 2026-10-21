#import "ProcessTap.h"

CATapDescription *ACMakeTapDescription(NSArray<NSNumber *> *processes, NSArray<NSString *> *bundleIDs, BOOL global) {
    CATapDescription *description = global ? [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:processes] : [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    description.name = @"AudioChain interception";
    description.privateTap = YES;
    description.muteBehavior = CATapMutedWhenTapped;
    if (@available(macOS 26.0, *)) {
        description.bundleIDs = bundleIDs;
        description.processRestoreEnabled = YES;
    }
    return description;
}
CATapDescription *ACMakeDeviceTapDescription(NSArray<NSNumber *> *processes, NSArray<NSString *> *bundleIDs, BOOL global, NSString *deviceUID) {
    CATapDescription *description = global ? [[CATapDescription alloc] initExcludingProcesses:processes andDeviceUID:deviceUID withStream:0] : [[CATapDescription alloc] initWithProcesses:processes andDeviceUID:deviceUID withStream:0];
    description.name = @"AudioChain exact PCM";
    description.privateTap = YES;
    description.muteBehavior = CATapMutedWhenTapped;
    if (@available(macOS 26.0, *)) { description.bundleIDs = bundleIDs; description.processRestoreEnabled = YES; }
    return description;
}
OSStatus ACUpdateTapProcesses(AudioObjectID tap, NSArray<NSNumber *> *processes, NSArray<NSString *> *bundleIDs) {
    AudioObjectPropertyAddress address = { kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CATapDescription *description = nil;
    UInt32 size = sizeof(description);
    OSStatus status = AudioObjectGetPropertyData(tap, &address, 0, NULL, &size, &description);
    if (status != noErr || !description) return status;
    description.processes = processes;
    if (@available(macOS 26.0, *)) description.bundleIDs = bundleIDs;
    return AudioObjectSetPropertyData(tap, &address, 0, NULL, sizeof(description), &description);
}
