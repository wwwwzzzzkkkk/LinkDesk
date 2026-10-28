#include "../macOS/LDCursorFlow.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    LDCursorFlow flow={0};
    for (unsigned i=1;i<=4;i++) { assert(LDCursorCanSend(&flow)); LDCursorDidSend(&flow,i); }
    assert(!LDCursorCanSend(&flow));
    assert(!LDCursorDidAck(&flow,2) && flow.count==4);
    assert(LDCursorDidAck(&flow,1) && LDCursorCanSend(&flow));
    LDCursorDidSend(&flow,100); assert(flow.count==4);
    for (unsigned i=2;i<=4;i++) assert(LDCursorDidAck(&flow,i));
    assert(LDCursorDidAck(&flow,100) && flow.count==0);
    assert(!LDCursorDidAck(&flow,100));
    puts("CURSOR_FLOW_PASS: four-frame bounded pipeline, ordered ACK, freshest update after congestion");
}
