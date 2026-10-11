#import <Foundation/Foundation.h>
@interface LDMicrophoneBridge : NSObject
@property(nonatomic, readonly) NSString *status;
- (BOOL)start;
- (void)setEnabled:(BOOL)enabled;
- (void)stop;
@end
