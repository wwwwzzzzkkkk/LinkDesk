#pragma once
// Keep the target clock's phase across slightly irregular capture callbacks.
// Reset after a stall instead of sending a burst to catch up with old deadlines.
static inline double LDAdvanceFrameDeadline(double now, double deadline, double interval) {
    return deadline <= 0 || now - deadline > interval ? now + interval : deadline + interval;
}
