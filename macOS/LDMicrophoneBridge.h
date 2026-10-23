#import <Foundation/Foundation.h>
@interface LDMicrophoneBridge : NSObject
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) BOOL enabled;
@property(nonatomic, readonly) BOOL running;
- (void)updateRoute;
- (char)controlReplyForCommand:(const char *)command length:(size_t)length;
- (BOOL)start;
- (void)setEnabled:(BOOL)enabled;
- (void)stop;
@end
