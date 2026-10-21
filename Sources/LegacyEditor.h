#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import "ProcessTap.h"
#import "AudioRing.h"
#import "DirectTransport.h"
#import "LevelMeter.h"
#import "RenderProbe.h"
#import "SystemMetrics.h"

NS_ASSUME_NONNULL_BEGIN
@interface ACLegacyEditor : NSObject
@property(nonatomic, readonly, strong) NSView *view;
@end
FOUNDATION_EXPORT ACLegacyEditor * _Nullable ACCreateLegacyEditor(AudioUnit unit, NSError **error);
NS_ASSUME_NONNULL_END
