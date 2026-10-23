#import "../macOS/LDMicrophoneBridge.m"
#import <assert.h>
// Exercise the production command handler without changing the user's audio route.
@interface TestMic : LDMicrophoneBridge
@property(nonatomic) BOOL testEnabled;
@property(nonatomic) BOOL testRunning;
@property(nonatomic) int mutations;
@end
@implementation TestMic
- (BOOL)enabled { return _testEnabled; }
- (BOOL)running { return _testRunning; }
- (void)setEnabled:(BOOL)value { if (_testRunning) { _testEnabled=value; _mutations++; } }
@end
int main(){@autoreleasepool{
 TestMic *mic=[TestMic new];mic.testRunning=YES;
 assert([mic controlReplyForCommand:"LDMICGET" length:8]=='0');
 assert([mic controlReplyForCommand:"LDMICON1" length:8]=='1');
 assert([mic controlReplyForCommand:"LDMICGET" length:8]=='1');
 // A Mac-side change is returned to the tablet by the next GET.
 [mic setEnabled:NO];assert([mic controlReplyForCommand:"LDMICGET" length:8]=='0');
 [mic setEnabled:YES];assert([mic controlReplyForCommand:"LDMICOFF" length:8]=='0');
 int mutations=mic.mutations;
 assert([mic controlReplyForCommand:"LDMICON1" length:7]=='E');
 assert([mic controlReplyForCommand:"UNKNOWN!" length:8]=='E');
 assert(mic.mutations==mutations);
 mic.testRunning=NO;assert([mic controlReplyForCommand:"LDMICON1" length:8]=='E');assert(!mic.enabled);
 puts("MIC_CONTROL_PASS: both directions, off, unavailable, malformed commands");
}}
