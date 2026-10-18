#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
/// The display/audio engine lives inside the single LinkDesk process and signing identity.
@interface LDDesktopController : NSObject
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) BOOL starting;
@property(nonatomic, readonly) BOOL usbReady;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) NSString *statusDetail;
@property(nonatomic, readonly) NSString *audioStatus;
@property(nonatomic, readonly) NSString *microphoneStatus;
@property(nonatomic, readonly) NSInteger scaleIndex;
@property(nonatomic, readonly) NSInteger targetFPS;
@property(nonatomic, readonly) double audioDelay;
@property(nonatomic, readonly) BOOL microphoneEnabled;
- (BOOL)runDisplaySelfTest;
- (void)prepare;
- (void)shutdown;
- (void)toggleDesktop;
- (void)selectScale:(NSInteger)index;
- (void)selectFrameRate:(NSInteger)fps;
- (void)enableMicrophone:(BOOL)enabled;
- (void)selectTabletSpeaker;
- (void)restoreMacSpeaker;
- (void)selectAudioDelay:(double)delay;
- (void)openDisplaySettings;
- (void)showDisplayTest;
@end
NS_ASSUME_NONNULL_END
