#import "LegacyEditor.h"
#import <AudioToolbox/AUCocoaUIView.h>

@interface ACLegacyEditor ()
@property(nonatomic, readwrite, strong) NSView *view;
@property(nonatomic, strong) id factory;
@property(nonatomic, strong) NSBundle *bundle;
@end
@implementation ACLegacyEditor
@end

static void ACEditorError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"AudioChain.PluginEditor" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

ACLegacyEditor *ACCreateLegacyEditor(AudioUnit unit, NSError **error) {
    NSCAssert([NSThread isMainThread], @"AU Cocoa views must be created on the main thread");
    UInt32 size = 0;
    OSStatus status = AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, NULL);
    if (status == kAudioUnitErr_InvalidProperty) return nil; // No custom Cocoa editor.
    size_t offset = offsetof(AudioUnitCocoaViewInfo, mCocoaAUViewClass);
    if (status != noErr || size < offset + sizeof(CFStringRef) || size > 1024 * 1024) {
        ACEditorError(error, [NSString stringWithFormat:@"Не удалось получить Cocoa-редактор AU (%d).", (int)status]);
        return nil;
    }
    AudioUnitCocoaViewInfo *info = calloc(1, size);
    UInt32 actualSize = size;
    status = AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, info, &actualSize);
    if (status != noErr) {
        free(info);
        ACEditorError(error, [NSString stringWithFormat:@"Не удалось прочитать Cocoa-редактор AU (%d).", (int)status]);
        return nil;
    }
    NSUInteger count = (MIN(actualSize, size) - offset) / sizeof(CFStringRef);
    ACLegacyEditor *editor = nil;
    @try {
        NSURL *url = (__bridge NSURL *)info->mCocoaAUViewBundleLocation;
        NSBundle *bundle = url ? [NSBundle bundleWithURL:url] : nil;
        if (!bundle) { ACEditorError(error, @"Плагин не указал доступный bundle редактора."); }
        else {
            NSError *loadError = nil;
            if (![bundle loadAndReturnError:&loadError]) {
                ACEditorError(error, loadError.localizedDescription ?: @"Не удалось загрузить bundle редактора.");
            } else {
                for (NSUInteger i = 0; i < count; i++) {
                    NSString *name = (__bridge NSString *)info->mCocoaAUViewClass[i];
                    if (!name) continue;
                    Class factoryClass = [bundle classNamed:name];
                    id factory = factoryClass ? [[factoryClass alloc] init] : nil;
                    if (![factory respondsToSelector:@selector(uiViewForAudioUnit:withSize:)]) continue;
                    NSView *view = [(id<AUCocoaUIBase>)factory uiViewForAudioUnit:unit withSize:NSMakeSize(1000, 700)];
                    if (![view isKindOfClass:[NSView class]]) continue;
                    editor = [[ACLegacyEditor alloc] init];
                    editor.view = view; editor.factory = factory; editor.bundle = bundle;
                    break;
                }
                if (!editor) ACEditorError(error, @"Cocoa-фабрика плагина не создала редактор.");
            }
        }
    } @catch (NSException *exception) {
        ACEditorError(error, [NSString stringWithFormat:@"Ошибка редактора AU: %@", exception.reason ?: exception.name]);
    } @finally {
        if (info->mCocoaAUViewBundleLocation) CFRelease(info->mCocoaAUViewBundleLocation);
        for (NSUInteger i = 0; i < count; i++) if (info->mCocoaAUViewClass[i]) CFRelease(info->mCocoaAUViewClass[i]);
        free(info);
    }
    return editor;
}
