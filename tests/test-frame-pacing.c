#include "../macOS/LDFramePacing.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    // A 100 Hz source must supply almost 60 unique frames/s at a 60 Hz target,
    // rather than quantizing to every second source update (50 Hz).
    double deadline=0; int captured=0,lastSent=0,sent=0;
    for(int ms=1;ms<=4000;ms++) {
        if(ms%10==0)captured++;
        if(captured>lastSent && ms/1000.0+.0005>=deadline) {
            lastSent=captured;sent++;
            deadline=LDAdvanceFrameDeadline(ms/1000.0,deadline,1.0/60);
        }
    }
    assert(sent>=238 && sent<=241);
    assert(LDAdvanceFrameDeadline(10,1,1.0/144)>10);
    // On-time calls preserve phase despite sub-millisecond scheduler jitter.
    double next=LDAdvanceFrameDeadline(1.0003,1,1.0/120);
    assert(next>1.0083 && next<1.0084);
    printf("FRAME_PACING_PASS: irregular source produced %d unique frames in 4 s; stall recovery, phase\n",sent);
}
