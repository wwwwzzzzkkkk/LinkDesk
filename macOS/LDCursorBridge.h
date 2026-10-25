#import <Cocoa/Cocoa.h>

// Cursor pixels travel independently of the video encoder and its reference frames.
@interface LDCursorBridge : NSObject
- (void)startForDisplay:(CGDirectDisplayID)display modeChanged:(void (^)(BOOL separated))changed;
- (void)stop;
@end
