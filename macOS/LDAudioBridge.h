#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
@interface LDAudioBridge : NSObject
@property(nonatomic, readonly) NSString *status;
- (BOOL)start;
- (void)stop;
- (void)updateRoute;
- (void)setSyncDelay:(double)milliseconds;
@end
