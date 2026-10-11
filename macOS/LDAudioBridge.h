#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
@interface LDAudioBridge : NSObject
@property(nonatomic, readonly) NSString *status;
- (BOOL)start;
- (BOOL)selectTabletOutput;
- (void)restoreOutput;
- (void)stop;
- (void)updateRoute;
- (void)setSyncDelay:(double)milliseconds;
@end
