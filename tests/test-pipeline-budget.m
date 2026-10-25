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
 // A high-refresh tail can exceed 45 ms without admitting an unbounded queue.
 for(int i=0;i<6;i++)assert([b reserve:500+i now:2+i*.009 limit:6 maxAge:.070]);
 assert(![b reserve:600 now:2.055 limit:6 maxAge:.070]);
 b.frames.firstObject.sent=YES;[b ack:500];
 assert(![b reserve:700 now:2.081 limit:6 maxAge:.070]);
 puts("PIPELINE_BUDGET_PASS: latency pressure, admission cap, sent ACKs, errors, reconnect epoch");
}}
