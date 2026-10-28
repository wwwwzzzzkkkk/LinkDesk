#pragma once
// Keep the target clock's phase across slightly irregular capture callbacks.
// Reset after a stall instead of sending a burst to catch up with old deadlines.
static inline double LDAdvanceFrameDeadline(double now, double deadline, double interval) {
    if (deadline <= 0 || now - deadline > interval) return now + interval;
    // A late callback must not be followed by a near-immediate catch-up frame.
    // Retain phase when possible, but leave at least half an interval of spacing.
    double phase = deadline + interval, earliest = now + interval * 0.5;
    return phase < earliest ? earliest : phase;
}
