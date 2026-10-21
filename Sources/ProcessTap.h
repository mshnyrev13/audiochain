#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT CATapDescription *ACMakeTapDescription(NSArray<NSNumber *> *processes, NSArray<NSString *> *bundleIDs, BOOL global);
FOUNDATION_EXPORT CATapDescription *ACMakeDeviceTapDescription(NSArray<NSNumber *> *processes, NSArray<NSString *> *bundleIDs, BOOL global, NSString *deviceUID);
FOUNDATION_EXPORT OSStatus ACUpdateTapProcesses(AudioObjectID tap, NSArray<NSNumber *> *processes, NSArray<NSString *> *bundleIDs);
NS_ASSUME_NONNULL_END
