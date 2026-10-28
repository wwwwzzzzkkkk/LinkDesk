#pragma once
#include <stdbool.h>
#include <stdint.h>

// Permit a small pipeline so one slow acknowledgement does not freeze rapid
// pointer motion; the cap still prevents an unbounded TCP backlog.
#define LD_CURSOR_FLIGHT_LIMIT 4
typedef struct { uint32_t sequences[LD_CURSOR_FLIGHT_LIMIT]; unsigned count; } LDCursorFlow;
static inline bool LDCursorCanSend(const LDCursorFlow *flow) { return flow->count < LD_CURSOR_FLIGHT_LIMIT; }
static inline void LDCursorDidSend(LDCursorFlow *flow, uint32_t sequence) { if (LDCursorCanSend(flow)) flow->sequences[flow->count++] = sequence; }
static inline bool LDCursorDidAck(LDCursorFlow *flow, uint32_t sequence) {
    if (!flow->count || sequence != flow->sequences[0]) return false;
    for (unsigned i=1; i<flow->count; i++) flow->sequences[i-1]=flow->sequences[i];
    flow->count--; return true;
}
