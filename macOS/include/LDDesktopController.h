#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
/// The display/audio engine lives inside the single LinkDesk process and signing identity.
@interface LDDesktopController : NSObject
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) CGDirectDisplayID touchDisplayID;
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
@property(nonatomic, readonly) BOOL hdrEnabled;
@property(nonatomic, readonly) BOOL hdrAvailable;
@property(nonatomic, readonly) NSInteger hdrShadows;
- (void)selectHDRShadows:(NSInteger)level;
@property(nonatomic, readonly) NSInteger colorEnhancement;
- (void)selectColorEnhancement:(NSInteger)level;
- (void)enableHDR:(BOOL)enabled;
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
