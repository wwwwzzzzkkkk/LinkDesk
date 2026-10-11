#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
@interface LDSystemVolume : NSObject
- (BOOL)startWithControlDevice:(AudioDeviceID)control speaker:(AudioDeviceID)speaker;
- (void)setActive:(BOOL)active;
- (void)stop;
@end
