#import "../macOS/LDPipelineBudget.h"
#import <assert.h>
int main(){@autoreleasepool{
 LDPipelineBudget *b=[LDPipelineBudget new];[b reset:1];
 LDFrameTicket *a=[b reserve:100 now:1 limit:5 maxAge:.030];
 LDFrameTicket *c=[b reserve:200 now:1.007 limit:5 maxAge:.030];
 assert(a&&c);assert(![b reserve:300 now:1.031 limit:5 maxAge:.030]);
 // Unsent reservations cannot be released by ACKs for earlier compressed output.
 a.sent=YES;[b ack:200];assert(![b contains:a]&&[b contains:c]);
 LDFrameTicket *d=[b reserve:300 now:1.032 limit:2 maxAge:.030];assert(d);
 assert(![b reserve:400 now:1.033 limit:2 maxAge:.030]);
 [b releaseFrame:d];assert([b reserve:400 now:1.034 limit:2 maxAge:.030]);
 [b reset:2];assert(![b contains:c]);[b releaseFrame:c];assert(b.frames.count==0);
 puts("PIPELINE_BUDGET_PASS: latency pressure, admission cap, sent ACKs, errors, reconnect epoch");
}}
