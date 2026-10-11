#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <arpa/inet.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>
#import <stdatomic.h>
#import "LDPipelineBudget.h"
#import "LDAudioBridge.h"
#import "LDMicrophoneBridge.h"
#import <CoreAudio/CoreAudio.h>

// These private CoreGraphics declarations are isolated here. Resolve at runtime.
@interface LDDisplayDescriptor : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh, vendorID, productID, serialNum;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) CGPoint whitePoint, redPrimary, greenPrimary, bluePrimary;
@property(nonatomic, strong) dispatch_queue_t queue;
@end
@interface LDDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
@end
@interface LDDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end
@interface LDVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(LDDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(LDDisplaySettings *)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

// Transport pixels stay fixed while the desktop's logical size changes.
static const uint32_t LDWidth = 2880, LDHeight = 1920;
static uint32_t LDFPS = 60;
static const uint32_t LDLogicalWidths[] = {1152, 1296, 1440, 1680, 1920};
static const uint16_t LDPort = 24832;
static const uint16_t LDControlPort = 24834;
static NSString *const HDC = @"/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc";
static void append32(NSMutableData *data, uint32_t n) { n = htonl(n); [data appendBytes:&n length:4]; }
static void append64(NSMutableData *data, uint64_t n) { n = CFSwapInt64HostToBig(n); [data appendBytes:&n length:8]; }

@interface LDTestView : NSView
@end
@implementation LDTestView
- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithCalibratedRed:0.055 green:0.075 blue:0.12 alpha:1] setFill]; NSRectFill(self.bounds);
    NSDictionary *heading = @{NSFontAttributeName:[NSFont systemFontOfSize:42 weight:NSFontWeightSemibold], NSForegroundColorAttributeName:NSColor.whiteColor};
    [@"连屏 LinkDesk" drawAtPoint:NSMakePoint(50, self.bounds.size.height - 110) withAttributes:heading];
    NSDictionary *body = @{NSFontAttributeName:[NSFont systemFontOfSize:22], NSForegroundColorAttributeName:NSColor.lightGrayColor};
    [@"这是独立的 Mac 扩展桌面" drawAtPoint:NSMakePoint(50, self.bounds.size.height - 170) withAttributes:body];
    [@"HiDPI · 2880 × 1920 高清传输" drawAtPoint:NSMakePoint(50, self.bounds.size.height - 210) withAttributes:body];
    NSArray<NSColor *> *colors = @[NSColor.systemBlueColor, NSColor.systemPurpleColor, NSColor.systemPinkColor, NSColor.systemOrangeColor, NSColor.systemGreenColor];
    CGFloat w = (self.bounds.size.width - 100) / colors.count;
    for (NSUInteger i = 0; i < colors.count; i++) { [colors[i] setFill]; NSRectFill(NSMakeRect(50+i*w, 130, w, 110)); }
    // The animated marker is a composited layer, so static text is not repainted at 144 Hz.
}
@end

@interface LinkDesk : NSObject <NSApplicationDelegate, NSWindowDelegate, SCStreamOutput, SCStreamDelegate> {
    LDVirtualDisplay *_display;
    SCStream *_stream;
    LDAudioBridge *_audio;
    LDMicrophoneBridge *_microphone;
    NSButton *_microphoneToggle;
    NSTextField *_microphoneHint;
    NSSlider *_audioSyncSlider;
    NSTextField *_audioSyncLabel;
    NSTextField *_audioHint;
    VTCompressionSessionRef _encoder;
    CMSampleBufferRef _latestFrame;
    dispatch_source_t _encodeWake;
    NSLock *_networkLock;
    int _listenFD, _clientFD;
    uint64_t _framesSent, _bytesSent;
    BOOL _active, _starting;
    BOOL _forceKeyframe;
    unsigned _generation;
    uint64_t _clientEpoch;
    NSString *_target;
    dispatch_queue_t _captureQueue, _networkQueue;
    dispatch_group_t _acceptGroup;
    dispatch_group_t _feedbackGroup;
    BOOL _baseline, _hasFeedback;
    uint64_t _framesAcked;
    double _feedbackTotal, _feedbackMax, _feedbackLast;
    unsigned _feedbackSamples;
    LDPipelineBudget *_pipelineBudget;
    NSWindow *_window;
    NSTextField *_status, *_detail;
    NSButton *_toggle;
    NSTimer *_timer;
    NSString *_phase;
    NSWindow *_testWindow;
    CADisplayLink *_testTimer;
    CALayer *_testMarker;
    NSSegmentedControl *_scalePicker;
    NSTextField *_scaleHint;
    NSInteger _scaleIndex;
    BOOL _scaleReady;
    NSSegmentedControl *_fpsPicker;
    BOOL _useHEVC;
    uint64_t _lastStatsAck;
    double _lastStatsTime, _decodedFPS;
    uint32_t _tabletRefreshHz;
    NSLock *_metricsLock;
    uint64_t _captureCount, _encodeCount, _skipCount, _sendCount;
    double _sendMs, _sendMaxMs, _queueMs, _submitMs, _submitMaxMs;
    uint64_t _submitCount;
    NSUInteger _maxPacketBytes;
    double _captureAgeTotal, _encodeAgeTotal, _encodeWaitTotal;
    BOOL _logMetrics;
    int _controlFD;
    dispatch_group_t _controlGroup;
    NSTimer *_standbyTimer;
    BOOL _standbyProbeInFlight, _backgroundAgent;
    _Atomic(bool) _standbyReady;
    NSString *_standbyTarget;
}
- (void)probeStandbyUSB;
- (void)startControlListener;
- (void)stopControlListener;
- (void)drainLatestFrame;
- (void)encoded:(CMSampleBufferRef)sample ticket:(LDFrameTicket *)ticket;
- (void)encodingFinished:(LDFrameTicket *)ticket status:(OSStatus)status flags:(VTEncodeInfoFlags)flags sample:(CMSampleBufferRef)sample;
- (void)stop;
@end

@implementation LinkDesk
- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = _clientFD = _controlFD = -1;
        _controlGroup = dispatch_group_create();
        _backgroundAgent = [NSProcessInfo.processInfo.arguments containsObject:@"--background-agent"];
        _networkLock = [NSLock new];
        _metricsLock = [NSLock new];
        _captureQueue = dispatch_queue_create("LinkDesk.capture", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
        _encodeWake=dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD,0,0,_captureQueue);
        __weak LinkDesk *weakSelf=self;
        dispatch_source_set_event_handler(_encodeWake, ^{[weakSelf drainLatestFrame];});
        dispatch_resume(_encodeWake);
        _networkQueue = dispatch_queue_create("LinkDesk.send", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));
        _acceptGroup = dispatch_group_create();
        _feedbackGroup = dispatch_group_create();
        _baseline = [NSProcessInfo.processInfo.arguments containsObject:@"--baseline-encoder"];
        _pipelineBudget = [LDPipelineBudget new];
        _audio = [LDAudioBridge new];
        _microphone = [LDMicrophoneBridge new];

        _phase = @"准备连接";
        id savedScale = [NSUserDefaults.standardUserDefaults objectForKey:@"LinkDeskScaleIndex"];
        _scaleIndex = savedScale ? MAX(0, MIN(4, [savedScale integerValue])) : 2;
        NSInteger requestedFPS = [NSUserDefaults.standardUserDefaults integerForKey:@"LinkDeskTargetFPS"];
        NSArray *arguments = NSProcessInfo.processInfo.arguments;
        _logMetrics = [arguments containsObject:@"--metrics"];
        NSUInteger fpsArgument = [arguments indexOfObject:@"--fps"];
        if (fpsArgument != NSNotFound && fpsArgument + 1 < arguments.count) requestedFPS = [arguments[fpsArgument + 1] integerValue];
        LDFPS = (requestedFPS == 120 || requestedFPS == 144) ? (uint32_t)requestedFPS : 60;
        _useHEVC = LDFPS > 60;
    }
    return self;
}
- (void)showStatus:(NSString *)text detail:(NSString *)detail {
    NSAssert([NSThread isMainThread], @"Main thread required");
    _phase = text;
    _status.stringValue = text;
    _detail.stringValue = detail ?: @"";
    NSLog(@"LinkDesk: %@ — %@", text, detail ?: @"");
}
- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.alignment = NSTextAlignmentCenter;
    return field;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSProcessInfo.processInfo disableAutomaticTermination:@"LinkDesk USB standby service"];
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 580, 810)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"连屏 LinkDesk";
    _window.delegate = self;
    [_window center];
    NSView *view = _window.contentView;
    NSTextField *title = [self label:@"让桌面延伸到 MatePad" size:27 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(30, 310, 520, 48); [view addSubview:title];
    NSTextField *subtitle = [self label:@"USB 有线连接 · 独立扩展桌面" size:15 weight:NSFontWeightRegular];
    subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.frame = NSMakeRect(30, 278, 520, 28); [view addSubview:subtitle];
    _status = [self label:@"准备连接" size:20 weight:NSFontWeightMedium];
    _status.frame = NSMakeRect(30, 218, 520, 36); [view addSubview:_status];
    _detail = [self label:@"用数据线连接平板，然后打开平板上的「连屏」。" size:13 weight:NSFontWeightRegular];
    _detail.textColor = NSColor.secondaryLabelColor;
    _detail.frame = NSMakeRect(35, 137, 510, 76); [view addSubview:_detail];
    _toggle = [NSButton buttonWithTitle:@"启动有线副屏" target:self action:@selector(toggle:)];
    _toggle.bezelStyle = NSBezelStyleRounded;
    _toggle.controlSize = NSControlSizeLarge;
    _toggle.frame = NSMakeRect(180, 85, 220, 38); [view addSubview:_toggle];
    NSButton *settings = [NSButton buttonWithTitle:@"排列显示器…" target:self action:@selector(openDisplays:)];
    settings.bezelStyle = NSBezelStyleRounded;
    settings.frame = NSMakeRect(125, 34, 140, 30); [view addSubview:settings];
    NSButton *test = [NSButton buttonWithTitle:@"显示测试画面" target:self action:@selector(showTest:)];
    test.bezelStyle = NSBezelStyleRounded; test.frame = NSMakeRect(300, 34, 150, 30); [view addSubview:test];
    _audioHint = [self label:@"连接后可在 Mac 声音输出中选择 MatePad" size:12 weight:NSFontWeightRegular];
    _audioHint.frame=NSMakeRect(20,10,540,20);_audioHint.textColor=NSColor.secondaryLabelColor;[view addSubview:_audioHint];
    for (NSView *child in view.subviews) {
        NSRect frame = child.frame; frame.origin.y += 160; child.frame = frame;
    }
    NSTextField *scaleTitle = [self label:@"显示大小" size:17 weight:NSFontWeightMedium];
    scaleTitle.frame = NSMakeRect(30, 142, 520, 25); [view addSubview:scaleTitle];
    _scalePicker = [NSSegmentedControl segmentedControlWithLabels:@[@"更大字体", @"较大", @"默认", @"较多空间", @"更多空间"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeScale:)];
    _scalePicker.frame = NSMakeRect(30, 91, 520, 38);
    for (NSInteger i = 0; i < 5; i++) [_scalePicker setWidth:101 forSegment:i];
    _scalePicker.selectedSegment = _scaleIndex; [view addSubview:_scalePicker];
    _scaleHint = [self label:@"调整文字和窗口大小，保持高清传输" size:13 weight:NSFontWeightRegular];
    _scaleHint.textColor = NSColor.secondaryLabelColor;
    _scaleHint.frame = NSMakeRect(30, 35, 520, 46); [view addSubview:_scaleHint];
    [self refreshScaleHint];
    for (NSView *child in view.subviews) {
        NSRect frame = child.frame; frame.origin.y += 80; child.frame = frame;
    }
    NSTextField *fpsLabel = [self label:@"目标帧率" size:15 weight:NSFontWeightMedium];
    fpsLabel.frame = NSMakeRect(30, 34, 100, 23); [view addSubview:fpsLabel];
    _fpsPicker = [NSSegmentedControl segmentedControlWithLabels:@[@"60 帧", @"120 帧", @"144 帧"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(changeFPS:)];
    _fpsPicker.frame = NSMakeRect(150, 27, 400, 35);
    for (NSInteger i = 0; i < 3; i++) [_fpsPicker setWidth:127 forSegment:i];
    _fpsPicker.selectedSegment = LDFPS == 120 ? 1 : (LDFPS == 144 ? 2 : 0);
    _fpsPicker.toolTip = @"保持 2880 × 1920。切换会重新连接，实际帧率取决于两端性能。";
    [view addSubview:_fpsPicker];
    for (NSView *child in view.subviews) { NSRect f=child.frame;f.origin.y+=50;child.frame=f; }
    double audioDelay=[NSUserDefaults.standardUserDefaults objectForKey:@"LinkDeskAudioSyncDelay"] ? [NSUserDefaults.standardUserDefaults doubleForKey:@"LinkDeskAudioSyncDelay"] : 20;
    [_audio setSyncDelay:audioDelay];
    _audioSyncLabel=[self label:[NSString stringWithFormat:@"双端同步：Mac 延后 %.0f 毫秒",audioDelay] size:12 weight:NSFontWeightRegular];
    _audioSyncLabel.frame=NSMakeRect(20,20,230,20);[view addSubview:_audioSyncLabel];
    _audioSyncSlider=[NSSlider sliderWithValue:audioDelay minValue:0 maxValue:150 target:self action:@selector(changeAudioSync:)];
    _audioSyncSlider.frame=NSMakeRect(265,18,270,24);[view addSubview:_audioSyncSlider];
    for (NSView *child in view.subviews) { NSRect f=child.frame;f.origin.y+=120;child.frame=f; }
    NSButton *tabletSpeaker=[NSButton buttonWithTitle:@"使用平板扬声器" target:self action:@selector(useTabletSpeaker:)];
    tabletSpeaker.frame=NSMakeRect(25,78,170,30);tabletSpeaker.bezelStyle=NSBezelStyleRounded;[view addSubview:tabletSpeaker];
    NSButton *macSpeaker=[NSButton buttonWithTitle:@"恢复 Mac 扬声器" target:self action:@selector(useMacSpeaker:)];
    macSpeaker.frame=NSMakeRect(205,78,170,30);macSpeaker.bezelStyle=NSBezelStyleRounded;[view addSubview:macSpeaker];
    _microphoneToggle=[NSButton checkboxWithTitle:@"使用平板麦克风作为 Mac 输入" target:self action:@selector(changeMicrophone:)];
    _microphoneToggle.frame=NSMakeRect(30,44,510,26);[view addSubview:_microphoneToggle];
    _microphoneHint=[self label:@"请先在平板连屏中允许使用麦克风" size:12 weight:NSFontWeightRegular];
    _microphoneHint.frame=NSMakeRect(25,10,530,26);_microphoneHint.textColor=NSColor.secondaryLabelColor;[view addSubview:_microphoneHint];
    if (!_backgroundAgent) {
        [_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateStats:) userInfo:nil repeats:YES];
    [self startControlListener];
    _standbyTimer = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(probeStandbyUSB) userInfo:nil repeats:YES];
    [self probeStandbyUSB];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--start"]) [self toggle:nil];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    if (!visible) {
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [_window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    return YES;
}
- (void)refreshScaleHint {
    uint32_t width = LDLogicalWidths[_scaleIndex];
    _scaleHint.stringValue = [NSString stringWithFormat:@"相当于 %u × %u 的工作空间\n高清传输保持 2880 × 1920", width, width * 2 / 3];
}
- (void)changeFPS:(NSSegmentedControl *)sender {
    NSInteger index = sender.selectedSegment;
    if (index < 0 || index > 2) return;
    uint32_t fps = index == 1 ? 120 : (index == 2 ? 144 : 60);
    if (fps == LDFPS) return;
    BOOL restart = _active || _starting;
    if (restart) [self stop];
    LDFPS = fps; _useHEVC = fps > 60;
    [NSUserDefaults.standardUserDefaults setInteger:fps forKey:@"LinkDeskTargetFPS"];
    if (restart) [self toggle:nil];
}
- (BOOL)applyScaleIndex:(NSInteger)index persist:(BOOL)persist {
    if (!_display || index < 0 || index > 4) return NO;
    uint32_t width = LDLogicalWidths[index], height = width * 2 / 3;
    BOOL selected = NO;
    NSArray *modes = CFBridgingRelease(CGDisplayCopyAllDisplayModes(_display.displayID,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes:@YES}));
    for (id item in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)item;
        if (CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height &&
            CGDisplayModeGetPixelWidth(mode) == width * 2 && CGDisplayModeGetPixelHeight(mode) == height * 2 &&
            CGDisplayModeIsUsableForDesktopGUI(mode)) {
            selected = CGDisplaySetDisplayMode(_display.displayID, mode, NULL) == kCGErrorSuccess;
            break;
        }
    }
    CGDisplayModeRef actual = CGDisplayCopyDisplayMode(_display.displayID);
    BOOL verified = selected && actual && CGDisplayModeGetWidth(actual) == width &&
        CGDisplayModeGetHeight(actual) == height && CGDisplayModeGetPixelWidth(actual) == width * 2;
    if (actual) CFRelease(actual);
    if (verified) {
        _scaleIndex = index; _scalePicker.selectedSegment = index; [self refreshScaleHint];
        if (persist) [NSUserDefaults.standardUserDefaults setInteger:index forKey:@"LinkDeskScaleIndex"];
        NSLog(@"LinkDesk HiDPI: logical=%ux%u backing=%ux%u transport=%ux%u target_fps=%u", width, height, width * 2, height * 2, LDWidth, LDHeight, LDFPS);
    }
    return verified;
}
- (void)changeScale:(NSSegmentedControl *)sender {
    NSInteger requested = sender.selectedSegment;
    if (requested < 0 || requested > 4) return;
    if (!_display) {
        _scaleIndex = requested;
        [NSUserDefaults.standardUserDefaults setInteger:requested forKey:@"LinkDeskScaleIndex"];
        [self refreshScaleHint]; return;
    }
    if (!_scaleReady || ![self applyScaleIndex:requested persist:YES]) {
        sender.selectedSegment = _scaleIndex;
        _scaleHint.stringValue = @"显示模式还未就绪，请稍后再试。";
    }
}
- (void)syncSystemScale {
    if (!_display || !_scaleReady) return;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(_display.displayID);
    if (!mode) return;
    NSInteger match = -1;
    for (NSInteger i = 0; i < 5; i++) {
        if (CGDisplayModeGetWidth(mode) == LDLogicalWidths[i] &&
            CGDisplayModeGetPixelWidth(mode) == LDLogicalWidths[i] * 2) { match = i; break; }
    }
    if (match >= 0) {
        _scaleIndex = match; _scalePicker.selectedSegment = match; [self refreshScaleHint];
        [NSUserDefaults.standardUserDefaults setInteger:match forKey:@"LinkDeskScaleIndex"];
    } else {
        _scalePicker.selectedSegment = -1;
        _scaleHint.stringValue = [NSString stringWithFormat:@"系统自定义：%zu × %zu\n高清传输保持 2880 × 1920", CGDisplayModeGetWidth(mode), CGDisplayModeGetHeight(mode)];
    }
    CFRelease(mode);
}
- (void)showTest:(id)sender {
    if (!_display) return;
    [_testTimer invalidate]; [_testWindow close];
        // Use global coordinates even while AppKit's cached screen list is being refreshed.
        CGRect bounds = CGDisplayBounds(_display.displayID);
        CGFloat top = CGRectGetHeight(CGDisplayBounds(CGMainDisplayID()));
        NSRect frame = NSMakeRect(bounds.origin.x + 60, top - CGRectGetMaxY(bounds) + 80,
            MIN(1100, bounds.size.width - 120), MIN(760, bounds.size.height - 160));
        _testWindow = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
        _testWindow.releasedWhenClosed = NO;
        _testWindow.title = @"LinkDesk 扩展桌面测试"; _testWindow.contentView = [LDTestView new];
        _testWindow.contentView.wantsLayer = YES;
        _testMarker = [CALayer layer];
        _testMarker.bounds = CGRectMake(0, 0, 20, 25);
        _testMarker.position = CGPointMake(60, 82);
        _testMarker.backgroundColor = NSColor.whiteColor.CGColor;
        [_testWindow.contentView.layer addSublayer:_testMarker];
        [_testWindow orderFront:nil];
        [_testWindow setFrame:frame display:YES];
        NSLog(@"LinkDesk test window: %@", NSStringFromRect(_testWindow.frame));
        CABasicAnimation *movement = [CABasicAnimation animationWithKeyPath:@"position.x"];
        movement.fromValue = @(60);
        movement.toValue = @(MAX(61, _testWindow.contentView.bounds.size.width - 60));
        movement.duration = 4;
        movement.autoreverses = YES;
        movement.repeatCount = HUGE_VALF;
        movement.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        movement.preferredFrameRateRange = CAFrameRateRangeMake(60, 144, 144);
        [_testMarker addAnimation:movement forKey:@"high-refresh-motion"];
}
- (void)animateTest:(CADisplayLink *)link {
    CGFloat x = 60 + fmod(NSProcessInfo.processInfo.systemUptime * 160, MAX(1, _testWindow.contentView.bounds.size.width - 120));
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _testMarker.position = CGPointMake(x, 82);
    [CATransaction commit];
}
- (void)openDisplays:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Displays-Settings.extension"]];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { [self stopControlListener]; [self stop]; }
- (BOOL)createDisplay:(NSError **)error {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    if (!descriptorClass || !displayClass || !settingsClass || !modeClass) return NO;
    @try {
        LDDisplayDescriptor *descriptor = [descriptorClass new];
        descriptor.name = @"MatePad · LinkDesk";
        descriptor.maxPixelsWide = 3840; descriptor.maxPixelsHigh = 2560;
        descriptor.sizeInMillimeters = CGSizeMake(279, 186);
        descriptor.whitePoint = CGPointMake(0.3127, 0.3290);
        descriptor.redPrimary = CGPointMake(0.64, 0.33);
        descriptor.greenPrimary = CGPointMake(0.30, 0.60);
        descriptor.bluePrimary = CGPointMake(0.15, 0.06);
        descriptor.vendorID = 0x4c44; descriptor.productID = 0x132; descriptor.serialNum = 1320061;
        descriptor.queue = dispatch_get_main_queue();
        _display = [[displayClass alloc] initWithDescriptor:descriptor];
        LDDisplaySettings *settings = [settingsClass new];
        settings.hiDPI = 1;
        // macOS requires both the logical size and its 2x size in the mode table;
        // otherwise the generated HiDPI variant is listed but unusable by the desktop.
        NSMutableArray *advertisedModes = [NSMutableArray new];
        [advertisedModes addObject:[[modeClass alloc] initWithWidth:1920 height:1280 refreshRate:LDFPS]];
        for (NSInteger i = 0; i < 4; i++) {
            uint32_t width = LDLogicalWidths[i];
            [advertisedModes addObject:[[modeClass alloc] initWithWidth:width height:width * 2 / 3 refreshRate:LDFPS]];
        }
        for (NSInteger i = 0; i < 5; i++) {
            uint32_t width = LDLogicalWidths[i] * 2;
            [advertisedModes addObject:[[modeClass alloc] initWithWidth:width height:width * 2 / 3 refreshRate:LDFPS]];
        }
        settings.modes = advertisedModes;
        if (!_display || ![_display applySettings:settings]) { _display = nil; return NO; }
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGDirectDisplayID main = CGMainDisplayID();
            CGRect bounds = CGDisplayBounds(main);
            CGConfigureDisplayMirrorOfDisplay(config, _display.displayID, kCGNullDirectDisplay);
            NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"LinkDeskDisplayOrigin"];
            CGConfigureDisplayOrigin(config, _display.displayID,
                saved ? [saved[@"x"] intValue] : CGRectGetMaxX(bounds),
                saved ? [saved[@"y"] intValue] : CGRectGetMinY(bounds));
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
        NSLog(@"LinkDesk virtual display: id=%u size=%zux%zu mirrored=%d", _display.displayID,
            CGDisplayPixelsWide(_display.displayID), CGDisplayPixelsHigh(_display.displayID), CGDisplayIsInMirrorSet(_display.displayID));
        return CGDisplayIsActive(_display.displayID) && !CGDisplayIsInMirrorSet(_display.displayID);
    } @catch (NSException *exception) { NSLog(@"Virtual display failed: %@", exception.reason); _display = nil; return NO; }
}
- (NSString *)runHDC:(NSArray<NSString *> *)arguments success:(BOOL *)success {
    NSTask *task = [NSTask new];
    NSString *bundled=[NSBundle.mainBundle pathForResource:@"hdc" ofType:nil inDirectory:@"tools"];
    task.executableURL = [NSURL fileURLWithPath:bundled ?: HDC]; task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe; task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { *success = NO; return error.localizedDescription; }
    // hdc operations normally return immediately; bound a stuck tool process.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.running) [task terminate];
    });
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit]; *success = task.terminationStatus == 0;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}
- (void)probeStandbyUSB {
    if (_standbyProbeInFlight) return;
    _standbyProbeInFlight = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = NO;
        NSString *listing = [self runHDC:@[@"list", @"targets", @"-v"] success:&ok];
        NSMutableArray<NSString *> *targets = [NSMutableArray new];
        if (ok) for (NSString *line in [listing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if ([line containsString:@"USB"] && [line containsString:@"Connected"]) {
                NSString *key = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].firstObject;
                if (key.length) [targets addObject:key];
            }
        }
        NSString *target = targets.count == 1 ? targets.firstObject : nil;
        BOOL forwarded = NO;
        if (target) {
            NSString *existing = [self runHDC:@[@"-t", target, @"fport", @"ls"] success:&ok];
            for (NSString *line in [existing componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
                if ([line hasPrefix:[target stringByAppendingString:@" "]] &&
                    [line containsString:@"tcp:24834 tcp:24834"] && [line containsString:@"[Reverse]"]) forwarded = YES;
            }
            if (!forwarded) [self runHDC:@[@"-t", target, @"rport", @"tcp:24834", @"tcp:24834"] success:&forwarded];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_standbyProbeInFlight = NO;
            self->_standbyTarget = forwarded ? target : nil;
            atomic_store(&self->_standbyReady, forwarded && target != nil);
        });
    });
}
- (void)startControlListener {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_port = htons(LDControlPort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || listen(fd, 2)) {
        NSLog(@"LinkDesk control port unavailable: %d", errno); close(fd); return;
    }
    _controlFD = fd;
    dispatch_group_async(_controlGroup, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (YES) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) break;
            struct timeval timeout = {0, 500000};
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            char command[8]; ssize_t count = recv(client, command, sizeof(command), MSG_WAITALL);
            char reply = 'E';
            if (count == sizeof(command) && memcmp(command, "LDSTART1", 8) == 0) {
                if (!atomic_load(&self->_standbyReady)) reply = 'U';
                else if (!CGPreflightScreenCaptureAccess()) reply = 'P';
                else {
                    reply = 'S';
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!self->_active && !self->_starting && atomic_load(&self->_standbyReady)) [self toggle:nil];
                    });
                }
            }
            send(client, &reply, 1, MSG_NOSIGNAL);
            close(client);
        }
    });
}
- (void)stopControlListener {
    [_standbyTimer invalidate]; _standbyTimer = nil;
    atomic_store(&_standbyReady, false);
    if (_controlFD >= 0) { shutdown(_controlFD, SHUT_RDWR); close(_controlFD); _controlFD = -1; }
    dispatch_group_wait(_controlGroup, DISPATCH_TIME_FOREVER);
}
- (BOOL)selectNativeMode {
    BOOL ready = [self applyScaleIndex:_scaleIndex persist:NO];
    _scaleReady = ready;
    return ready;
}
- (void)toggle:(id)sender {
    if (_active || _starting) { [self stop]; return; }
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();
        [self showStatus:@"需要屏幕录制权限" detail:@"请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许「连屏」，然后退出并重新打开本应用。"];
        return;
    }
    _starting = YES; [_networkLock lock]; unsigned generation = ++_generation; [_networkLock unlock];
    _toggle.title = @"取消连接";
    [self showStatus:@"检查 USB 连接" detail:@"正在连接已授权的鸿蒙平板。"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL ok = NO;
        NSString *result = [self runHDC:@[@"list", @"targets", @"-v"] success:&ok];
        NSMutableArray<NSString *> *targets = [NSMutableArray new];
        for (NSString *line in [result componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if ([line containsString:@"USB"] && [line containsString:@"Connected"]) {
                NSArray *parts = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if ([parts.firstObject length]) [targets addObject:parts.firstObject];
            }
        }
        NSString *target = targets.count == 1 ? targets.firstObject : nil;
        if (target) [self runHDC:@[@"-t", target, @"rport", @"tcp:24832", @"tcp:24832"] success:&ok];
        if (target) [self runHDC:@[@"-t", target, @"rport", @"tcp:24833", @"tcp:24833"] success:&ok];
        if (target) [self runHDC:@[@"-t", target, @"rport", @"tcp:24835", @"tcp:24835"] success:&ok];
        NSString *forwards = target ? [self runHDC:@[@"-t", target, @"fport", @"ls"] success:&ok] : @"";
        BOOL ready = NO;
        for (NSString *line in [forwards componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (target && [line hasPrefix:[target stringByAppendingString:@" "]] && [line containsString:@"tcp:24832 tcp:24832"] && [line containsString:@"[Reverse]"]) ready = YES;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation) return;
            if (!ready) {
                [self stop];
                [self showStatus:@"USB 尚未就绪" detail:targets.count > 1 ? @"请只连接一台目标平板后重试。" : @"请连接数据线，在平板打开 USB 调试并允许此 Mac；确认已安装 DevEco Studio。"];
                return;
            }
            self->_target = target;
            if (![self createDisplay:nil] || ![self startListener]) {
                [self stop]; [self showStatus:@"无法创建副屏" detail:@"请查看日志：虚拟显示器创建失败，或本地连接端口已被占用。"];
                return;
            }
            [self->_audio start];
            [self->_microphone start];
            [self->_microphone setEnabled:self->_microphoneToggle.state==NSControlStateValueOn];
            self->_active = YES; self->_starting = NO; self->_toggle.title = @"停止副屏";
            [self showStatus:@"副屏已创建，等待平板" detail:@"打开平板上的「连屏」，即可显示独立桌面。"];
            // Let WindowServer finish attaching the display before selecting its final mode.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                if (generation != self->_generation) return;
                if (![self selectNativeMode]) {
                    [self stop]; [self showStatus:@"无法设置副屏分辨率" detail:@"系统未能选择所需的高清缩放模式，请重试。"];
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{
                    if (generation == self->_generation) [self startCapture:generation];
                });
            });
        });
    });
}
- (BOOL)startListener {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0}; addr.sin_family = AF_INET; addr.sin_port = htons(LDPort); addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) || listen(fd, 1)) { close(fd); return NO; }
    _listenFD = fd;
    unsigned generation = _generation;
    dispatch_group_async(_acceptGroup, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (YES) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) break;
            int yes = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
            struct timeval timeout = {1, 0}; setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            NSMutableData *header = [NSMutableData dataWithBytes:self->_useHEVC ? "LDH1" : "LDV1" length:4];
            append32(header, LDWidth); append32(header, LDHeight); append32(header, LDFPS);
            [self->_networkLock lock];
            if (generation != self->_generation) { close(client); [self->_networkLock unlock]; break; }
            if (self->_clientFD >= 0) { shutdown(self->_clientFD, SHUT_RDWR); close(self->_clientFD); }
            self->_clientFD = client;
            uint64_t clientEpoch = ++self->_clientEpoch;
            self->_framesSent = self->_bytesSent = self->_framesAcked = 0;
            self->_feedbackTotal = self->_feedbackMax = self->_feedbackLast = 0;
            self->_feedbackSamples = 0; self->_hasFeedback = NO;
            self->_lastStatsAck = 0; self->_lastStatsTime = NSProcessInfo.processInfo.systemUptime; self->_decodedFPS = 0;
            self->_tabletRefreshHz = 0;
            [self->_pipelineBudget reset:clientEpoch];
            self->_forceKeyframe = YES;
            if (![self sendBytes:header fd:client]) { close(client); self->_clientFD = -1; }
            int feedbackFD = self->_clientFD >= 0 ? dup(client) : -1;
            [self->_networkLock unlock];
            if (feedbackFD >= 0) dispatch_group_async(self->_feedbackGroup, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                uint8_t ack[16]; size_t received = 0;
                while (YES) {
                    ssize_t n = recv(feedbackFD, ack + received, sizeof(ack) - received, 0);
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) break;
                    received += n; if (received < sizeof(ack)) continue; received = 0;
                    if (memcmp(ack, "LDA1", 4)) break;
                    uint64_t timestamp; memcpy(&timestamp, ack + 8, 8); timestamp = CFSwapInt64BigToHost(timestamp);
                    uint32_t refresh; memcpy(&refresh, ack + 4, 4); refresh = ntohl(refresh);
                    double now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()));
                    double ms = (now - timestamp / 1000000.0) * 1000;
                    [self->_networkLock lock];
                    if (self->_clientFD == client && clientEpoch == self->_clientEpoch && generation == self->_generation) {
                        self->_framesAcked++; self->_hasFeedback = YES;
                        if (refresh >= 30 && refresh <= 240) self->_tabletRefreshHz = refresh;
                        [self->_pipelineBudget ack:timestamp];
                        dispatch_source_merge_data(self->_encodeWake,1);
                        if (ms >= 0 && ms < 10000) {
                            self->_feedbackLast = ms;
                            self->_feedbackTotal += ms; self->_feedbackMax = MAX(self->_feedbackMax, ms);
                            if (++self->_feedbackSamples >= 120) {
                                NSLog(@"LinkDesk render ACK: mode=%@ samples=%u mean_ms=%.2f max_ms=%.2f", self->_baseline ? @"baseline" : @"low-latency", self->_feedbackSamples, self->_feedbackTotal / self->_feedbackSamples, self->_feedbackMax);
                                self->_feedbackSamples = 0; self->_feedbackTotal = self->_feedbackMax = 0;
                            }
                        }
                    }
                    [self->_networkLock unlock];
                }
                close(feedbackFD);
                [self->_networkLock lock];
                if (self->_clientFD == client && clientEpoch == self->_clientEpoch && generation == self->_generation) {
                    shutdown(self->_clientFD, SHUT_RDWR); close(self->_clientFD); self->_clientFD = -1;
                    [self->_pipelineBudget reset:++self->_clientEpoch];
                }
                [self->_networkLock unlock];
            });
        }
    });
    return YES;
}
- (BOOL)sendBytes:(NSData *)data fd:(int)fd {
    const uint8_t *bytes = data.bytes; size_t left = data.length;
    while (left) {
        ssize_t sent = send(fd, bytes, left, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return NO;
        bytes += sent; left -= sent;
    }
    return YES;
}
- (void)startCapture:(unsigned)generation {
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self->_generation || !self->_active) return;
            SCDisplay *source = nil;
            for (SCDisplay *candidate in content.displays) if (candidate.displayID == self->_display.displayID) source = candidate;
            if (!source || error) { [self stop]; [self showStatus:@"无法采集扩展桌面" detail:error.localizedDescription ?: @"系统尚未暴露新显示器，请重新启动副屏。"] ; return; }
            NSMutableDictionary *spec = [@{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES} mutableCopy];
            BOOL lowLatency=!self->_baseline && !self->_useHEVC;
            if (lowLatency) spec[(__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
            OSStatus status = VTCompressionSessionCreate(NULL, LDWidth, LDHeight, self->_useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec,
                NULL, NULL, NULL, NULL, &self->_encoder);
            if(status!=noErr&&lowLatency){
                [spec removeObjectForKey:(__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl];lowLatency=NO;
                status=VTCompressionSessionCreate(NULL,LDWidth,LDHeight,self->_useHEVC?kCMVideoCodecType_HEVC:kCMVideoCodecType_H264,(__bridge CFDictionaryRef)spec,NULL,NULL,NULL,NULL,&self->_encoder);
            }
            NSLog(@"MOTION_ENCODER low_latency=%d create=%d",lowLatency,(int)status);
            if (status != noErr) { [self stop]; [self showStatus:@"无法启动视频编码" detail:@"系统编码器初始化失败。"] ; return; }
            VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
            VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
            // The selected low-latency encoder does not support MaxFrameDelayCount or
            // PrioritizeEncodingSpeedOverQuality. Bound transport via render ACKs instead.
            VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_ProfileLevel, self->_useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel);
            if (self->_useHEVC) {
                OSStatus delay = VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_MaxFrameDelayCount, (__bridge CFNumberRef)@(1));
                OSStatus speed = VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue);
                NSLog(@"LinkDesk HEVC low-delay setup: delay=%d speed=%d", (int)delay, (int)speed);
            }
            VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(self->_useHEVC ? LDFPS * 450000 : 26000000));
            VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@(LDFPS));
            // A full-resolution IDR every second creates periodic encode/USB stalls.
            // Connections still explicitly force an immediate keyframe for recovery.
            NSInteger keyframeSeconds = self->_useHEVC ? 5 : 1;
            VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFNumberRef)@(LDFPS * keyframeSeconds));
            VTSessionSetProperty(self->_encoder, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFNumberRef)@(keyframeSeconds));
            if(self->_useHEVC&&!lowLatency) {
                if(@available(macOS 15.0,*)) {
                    OSStatus look=VTSessionSetProperty(self->_encoder,CFSTR("SuggestedLookAheadFrameCount"),(__bridge CFNumberRef)@0);
                    NSLog(@"MOTION_ENCODER lookahead_zero=%d",(int)look);
                }
            }
            VTCompressionSessionPrepareToEncodeFrames(self->_encoder);
            SCStreamConfiguration *config = [SCStreamConfiguration new];
            config.width = LDWidth; config.height = LDHeight; config.minimumFrameInterval = CMTimeMake(1, LDFPS);
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            // Three capture surfaces avoid starving the hardware encoder's retained input surfaces.
            NSInteger depth = self->_useHEVC ? 6 : 3;
            NSArray *arguments = NSProcessInfo.processInfo.arguments;
            NSUInteger depthIndex = [arguments indexOfObject:@"--capture-depth"];
            if (depthIndex != NSNotFound && depthIndex + 1 < arguments.count) depth = MAX(3, MIN(8, [arguments[depthIndex + 1] integerValue]));
            config.queueDepth = depth; config.showsCursor = YES; config.capturesAudio = NO;
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDisplay:source excludingWindows:@[]];
            self->_stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            NSError *outputError = nil;
            if (![self->_stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_captureQueue error:&outputError]) {
                [self stop]; [self showStatus:@"采集初始化失败" detail:outputError.localizedDescription]; return;
            }
            [self->_stream startCaptureWithCompletionHandler:^(NSError *captureError) {
                if (captureError) dispatch_async(dispatch_get_main_queue(), ^{
                    if (generation != self->_generation) return;
                    [self stop]; [self showStatus:@"采集失败" detail:captureError.localizedDescription];
                });
                else if ([NSProcessInfo.processInfo.arguments containsObject:@"--test-pattern"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{ if (generation == self->_generation) [self showTest:nil]; });
                }
            }];
        });
    }];
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{ if (stream != self->_stream) return; [self stop]; [self showStatus:@"桌面采集中断" detail:error.localizedDescription]; });
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sample ofType:(SCStreamOutputType)type {
    if (stream != _stream || type != SCStreamOutputTypeScreen || !_encoder || !CMSampleBufferIsValid(sample)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, NO);
    NSNumber *status = attachments.firstObject[SCStreamFrameInfoStatus];
    if (status && status.integerValue != SCFrameStatusComplete) return;
    CVImageBufferRef buffer = CMSampleBufferGetImageBuffer(sample); if (!buffer) return;
    if (_logMetrics) {
        double age = (CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) * 1000;
        [_metricsLock lock]; _captureCount++; _captureAgeTotal += age; [_metricsLock unlock];
    }
    // Keep a single freshest raw frame while the pipeline is busy. Never queue captures.
    if(_latestFrame) { CFRelease(_latestFrame); if(_logMetrics){[_metricsLock lock];_skipCount++;[_metricsLock unlock];} }
    _latestFrame=(CMSampleBufferRef)CFRetain(sample);
    [self drainLatestFrame];
}
- (void)drainLatestFrame {
    // Invoked only on the capture queue, including coalesced ACK wakeups.
    if(!_latestFrame||!_encoder)return;
    if(![_networkLock tryLock])return;
    CMSampleBufferRef sample=_latestFrame;
    BOOL connected = _clientFD >= 0;
    // Reserve BEFORE entering VideoToolbox, including the first frame before ACKs exist.
    // Drop only raw capture frames; never discard a referenced compressed frame.
    NSUInteger flightLimit = LDFPS > 60 ? (NSUInteger)ceil(LDFPS * 0.06) : 2;
    uint64_t pts = (uint64_t)CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sample), 1000000, kCMTimeRoundingMethod_Default).value;
    LDFrameTicket *ticket = connected ? [_pipelineBudget reserve:pts now:NSProcessInfo.processInfo.systemUptime limit:flightLimit] : nil;
    BOOL force = _forceKeyframe;
    if (ticket) { _forceKeyframe = NO; ticket.requestedKeyframe=force; }
    [_networkLock unlock];
    if(!ticket)return;
    _latestFrame=NULL;
    CVImageBufferRef buffer=CMSampleBufferGetImageBuffer(sample);
    NSDictionary *properties = force ? @{(__bridge NSString *)kVTEncodeFrameOptionKey_ForceKeyFrame:@YES} : nil;
    VTEncodeInfoFlags info = 0;
    double submitBegan=NSProcessInfo.processInfo.systemUptime;
    OSStatus encodeStatus = VTCompressionSessionEncodeFrameWithOutputHandler(_encoder, buffer, CMSampleBufferGetPresentationTimeStamp(sample), CMTimeMake(1, LDFPS), (__bridge CFDictionaryRef)properties, &info,
        ^(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef output) {
            [self encodingFinished:ticket status:status flags:flags sample:output];
        });
    if(_logMetrics){double ms=(NSProcessInfo.processInfo.systemUptime-submitBegan)*1000;[_metricsLock lock];_submitMs+=ms;_submitMaxMs=MAX(_submitMaxMs,ms);_submitCount++;[_metricsLock unlock];}
    CFRelease(sample);
    if (encodeStatus != noErr || (info & kVTEncodeInfo_FrameDropped)) {
        // Idempotent if a synchronous dropped/error callback already released it.
        [self encodingFinished:ticket status:encodeStatus flags:kVTEncodeInfo_FrameDropped sample:NULL];
    }
}
- (void)encodingFinished:(LDFrameTicket *)ticket status:(OSStatus)status flags:(VTEncodeInfoFlags)flags sample:(CMSampleBufferRef)sample {
    [_networkLock lock];
    BOOL current = _clientFD >= 0 && [_pipelineBudget contains:ticket];
    BOOL failed = status != noErr || !sample || (flags & kVTEncodeInfo_FrameDropped);
    if (current && failed) { [_pipelineBudget releaseFrame:ticket]; if(status!=noErr||ticket.requestedKeyframe)_forceKeyframe = YES; dispatch_source_merge_data(_encodeWake,1); }
    [_networkLock unlock];
    if (!current) return;
    if (failed) { NSLog(@"LinkDesk encode released: status=%d flags=%u", (int)status, (unsigned)flags); return; }
    if (_logMetrics) { [_metricsLock lock]; _encodeWaitTotal += (NSProcessInfo.processInfo.systemUptime - ticket.admittedAt) * 1000; [_metricsLock unlock]; }
    [self encoded:sample ticket:ticket];
}
- (void)encoded:(CMSampleBufferRef)sample ticket:(LDFrameTicket *)ticket {
    if (_logMetrics) {
        double age = (CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) * 1000;
        [_metricsLock lock]; _encodeCount++; _encodeAgeTotal += age; [_metricsLock unlock];
    }
    // Encoding admission already bounds this connection's complete pipeline.
    // A second three-packet cap disconnected healthy streams on output bursts.
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(sample, NO);
    BOOL sync = ![attachments.firstObject[(__bridge NSString *)kCMSampleAttachmentKey_NotSync] boolValue];
    NSMutableData *payload = [NSMutableData new]; const uint8_t start[] = {0, 0, 0, 1};
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    int nalLength = 4;
    if (sync) {
        size_t count = 0;
        if (_useHEVC) CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, NULL, NULL, &count, &nalLength);
        else CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, &count, &nalLength);
        for (size_t i = 0; i < count; i++) {
            const uint8_t *bytes; size_t length;
            OSStatus parameterResult = _useHEVC ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &bytes, &length, NULL, NULL)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, i, &bytes, &length, NULL, NULL);
            if (parameterResult == noErr) {
                [payload appendBytes:start length:4]; [payload appendBytes:bytes length:length];
            }
        }
    }
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t length = CMBlockBufferGetDataLength(block); NSMutableData *avcc = [NSMutableData dataWithLength:length];
    CMBlockBufferCopyDataBytes(block, 0, length, avcc.mutableBytes);
    const uint8_t *bytes = avcc.bytes;
    size_t offset = 0;
    while (offset + nalLength <= length) {
        uint32_t n = 0; for (int i = 0; i < nalLength; i++) n = (n << 8) | bytes[offset + i];
        offset += nalLength;
        if (!n || n > length - offset) break;
        [payload appendBytes:start length:4]; [payload appendBytes:bytes + offset length:n]; offset += n;
    }
    NSMutableData *packet = [NSMutableData new]; append32(packet, (uint32_t)payload.length); append32(packet, sync ? 1 : 0);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    uint64_t timestamp = (uint64_t)CMTimeConvertScale(pts, 1000000, kCMTimeRoundingMethod_Default).value;
    append64(packet, timestamp);
    [packet appendData:payload];
    double enqueuedAt=NSProcessInfo.processInfo.systemUptime;
    dispatch_async(_networkQueue, ^{
        [self->_networkLock lock];
        uint64_t epoch = ticket.epoch;
        int outputFD = self->_clientFD >= 0 && [self->_pipelineBudget contains:ticket] ? dup(self->_clientFD) : -1;
        if (outputFD >= 0) {
            // Mark before sending: a fast decoder can ACK before send() returns.
            ticket.sent = YES;
        } else if (self->_clientFD >= 0 && [self->_pipelineBudget contains:ticket]) {
            // A failed descriptor duplication must not strand a reservation.
            shutdown(self->_clientFD, SHUT_RDWR); close(self->_clientFD); self->_clientFD = -1;
            [self->_pipelineBudget reset:++self->_clientEpoch];
        }
        [self->_networkLock unlock];
        // Never hold the capture/ACK state lock during potentially blocking socket I/O.
        // dup() pins this connection; stop/reconnect shuts down all its duplicates.
        if (outputFD >= 0) {
            double sendingAt=NSProcessInfo.processInfo.systemUptime;
            BOOL sent = [self sendBytes:packet fd:outputFD]; close(outputFD);
            if(self->_logMetrics){
                double ms=(NSProcessInfo.processInfo.systemUptime-sendingAt)*1000;
                [self->_metricsLock lock];self->_sendCount++;self->_sendMs+=ms;self->_sendMaxMs=MAX(self->_sendMaxMs,ms);self->_queueMs+=(sendingAt-enqueuedAt)*1000;self->_maxPacketBytes=MAX(self->_maxPacketBytes,packet.length);[self->_metricsLock unlock];
            }
            [self->_networkLock lock];
            if (epoch == self->_clientEpoch && self->_clientFD >= 0) {
                if (sent) { self->_framesSent++; self->_bytesSent += packet.length; }
                else { shutdown(self->_clientFD, SHUT_RDWR); close(self->_clientFD); self->_clientFD = -1; }
            }
            [self->_networkLock unlock];
        }
    });
}
- (void)useTabletSpeaker:(id)sender {
    if(![_audio selectTabletOutput]) _audioHint.stringValue=@"请先启动副屏并连接平板";
}
- (void)useMacSpeaker:(id)sender { [_audio restoreOutput]; }
- (void)changeMicrophone:(NSButton *)button {
    if(!_active&&button.state==NSControlStateValueOn){button.state=NSControlStateValueOff;_microphoneHint.stringValue=@"请先启动副屏";return;}
    [_microphone setEnabled:button.state==NSControlStateValueOn];
    _microphoneHint.stringValue=_microphone.status;
}
- (void)changeAudioSync:(NSSlider *)slider {
    double delay=round(slider.doubleValue);[_audio setSyncDelay:delay];
    [NSUserDefaults.standardUserDefaults setDouble:delay forKey:@"LinkDeskAudioSyncDelay"];
    _audioSyncLabel.stringValue=[NSString stringWithFormat:@"双端同步：Mac 延后 %.0f 毫秒",delay];
}
- (void)updateStats:(NSTimer *)timer {
    if (!_active) return;
    [_audio updateRoute]; _audioHint.stringValue = _audio.status;
    _microphoneHint.stringValue = _microphone.status;
    [self syncSystemScale];
    if (![_networkLock tryLock]) return;
    BOOL connected = _clientFD >= 0; uint64_t frames = _framesSent;
    double now = NSProcessInfo.processInfo.systemUptime;
    if (_lastStatsTime > 0 && now > _lastStatsTime) _decodedFPS = (_framesAcked - _lastStatsAck) / (now - _lastStatsTime);
    _lastStatsAck = _framesAcked; _lastStatsTime = now;
    double decodedFPS = _decodedFPS; BOOL feedback = _hasFeedback; uint32_t refresh = _tabletRefreshHz;
    [_networkLock unlock];
    if (_logMetrics && connected) {
        [_metricsLock lock];
        NSLog(@"HFR_METRICS capture=%llu encoded=%llu skipped=%llu capture_age_ms=%.2f encoded_age_ms=%.2f decoded_fps=%.1f encode_wait_ms=%.2f send_ms=%.2f max_send_ms=%.2f queue_ms=%.2f max_packet_kib=%.1f submit_ms=%.2f max_submit_ms=%.2f", _captureCount, _encodeCount, _skipCount,
            _captureCount ? _captureAgeTotal / _captureCount : 0, _encodeCount ? _encodeAgeTotal / _encodeCount : 0, decodedFPS, _encodeCount ? _encodeWaitTotal / _encodeCount : 0, _sendCount ? _sendMs/_sendCount : 0, _sendMaxMs, _sendCount ? _queueMs/_sendCount : 0, _maxPacketBytes/1024.0, _submitCount ? _submitMs/_submitCount : 0, _submitMaxMs);
        _submitCount=0;_submitMs=_submitMaxMs=0;
        _sendCount=0;_sendMs=_sendMaxMs=_queueMs=0;_maxPacketBytes=0;
        _captureCount = _encodeCount = _skipCount = 0; _captureAgeTotal = _encodeAgeTotal = _encodeWaitTotal = 0;
        [_metricsLock unlock];
    }
    _status.stringValue = connected ? @"USB 已连接" : @"副屏已创建，等待平板";
    _detail.stringValue = connected ? [NSString stringWithFormat:@"2880 × 1920 · 目标 %u 帧/秒\n%@ · 已发送 %llu 帧\n静止画面会减少出帧。", LDFPS,
        feedback ? [NSString stringWithFormat:@"屏幕 %u Hz · 解码约 %.0f 帧/秒", refresh, decodedFPS] : @"等待显示反馈", frames]
        : @"打开平板上的「连屏」。若重新插拔过数据线，请停止后再次启动副屏。";
}
- (void)stop {
    _scaleReady = NO;
    if (_display) {
        CGRect bounds = CGDisplayBounds(_display.displayID);
        [NSUserDefaults.standardUserDefaults setObject:@{@"x":@(bounds.origin.x), @"y":@(bounds.origin.y)} forKey:@"LinkDeskDisplayOrigin"];
    }
    [_testTimer invalidate]; _testTimer = nil; [_testWindow close]; _testWindow = nil; _testMarker = nil;
    [_microphone stop];
    [_audio stop];
    _active = NO; _starting = NO;
    [_networkLock lock]; ++_generation;
    [_pipelineBudget reset:++_clientEpoch];
    if (_listenFD >= 0) { shutdown(_listenFD, SHUT_RDWR); close(_listenFD); _listenFD = -1; }
    if (_clientFD >= 0) { shutdown(_clientFD, SHUT_RDWR); close(_clientFD); _clientFD = -1; }
    [_networkLock unlock];
    dispatch_group_wait(_acceptGroup, DISPATCH_TIME_FOREVER);
    dispatch_group_wait(_feedbackGroup, DISPATCH_TIME_FOREVER);
    SCStream *oldStream = _stream; _stream = nil;
    [oldStream stopCaptureWithCompletionHandler:^(NSError *error) {}];
    dispatch_sync(_captureQueue, ^{
        if(self->_latestFrame){CFRelease(self->_latestFrame);self->_latestFrame=NULL;}
        if (self->_encoder) { VTCompressionSessionCompleteFrames(self->_encoder, kCMTimeInvalid); VTCompressionSessionInvalidate(self->_encoder); CFRelease(self->_encoder); self->_encoder = NULL; }
    });
    dispatch_sync(_networkQueue, ^{});
    _display = nil;
    _toggle.title = @"启动有线副屏";
    [self showStatus:@"副屏已停止" detail:@"扩展显示器已移除，窗口由 macOS 收回。"];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        LinkDesk *delegate = [LinkDesk new];
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--self-test"]) {
            BOOL ok = [delegate createDisplay:nil];
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
            ok = ok && [delegate selectNativeMode];
            for (NSInteger index = 0; index < 5 && ok; index++) ok = [delegate applyScaleIndex:index persist:NO];
            NSLog(@"SCALE_TEST %@", ok ? @"PASS" : @"FAIL");
            NSLog(@"SELF_TEST %@ screenCapturePermission=%d", ok ? @"PASS" : @"FAIL", CGPreflightScreenCaptureAccess());
            [delegate stop]; return ok ? 0 : 1;
        }
        BOOL backgroundAgent = [NSProcessInfo.processInfo.arguments containsObject:@"--background-agent"];
        [app setActivationPolicy:backgroundAgent ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular]; app.delegate = delegate;
        NSMenu *menu = [NSMenu new]; NSMenuItem *item = [NSMenuItem new]; [menu addItem:item];
        NSMenu *submenu = [NSMenu new]; [submenu addItemWithTitle:@"退出连屏" action:@selector(terminate:) keyEquivalent:@"q"]; item.submenu = submenu; app.mainMenu = menu;
        [app run];
    }
    return 0;
}
