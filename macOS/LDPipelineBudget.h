#import <Foundation/Foundation.h>

@interface LDFrameTicket : NSObject
@property(nonatomic) uint64_t epoch, pts;
@property(nonatomic) double admittedAt;
@property(nonatomic) BOOL sent, requestedKeyframe;
@end
@implementation LDFrameTicket
@end

// Caller serializes every operation with the connection lock. A reservation
// covers encoding, queued sends, transport and decoding until the Surface ACK.
@interface LDPipelineBudget : NSObject
@property(nonatomic) uint64_t epoch;
@property(nonatomic, strong) NSMutableArray<LDFrameTicket *> *frames;
- (void)reset:(uint64_t)epoch;
- (LDFrameTicket *)reserve:(uint64_t)pts now:(double)now limit:(NSUInteger)limit maxAge:(double)maxAge;
- (BOOL)contains:(LDFrameTicket *)ticket;
- (void)releaseFrame:(LDFrameTicket *)ticket;
- (void)ack:(uint64_t)pts;
@end
@implementation LDPipelineBudget
- (instancetype)init { if ((self = [super init])) _frames = [NSMutableArray new]; return self; }
- (void)reset:(uint64_t)epoch { _epoch = epoch; [_frames removeAllObjects]; }
- (LDFrameTicket *)reserve:(uint64_t)pts now:(double)now limit:(NSUInteger)limit maxAge:(double)maxAge {
    // Under age pressure permit only two in flight, rather than stopping completely
    // behind a single slow frame. The hard count cap always applies.
    if (_frames.count >= limit || (_frames.count >= 2 && now - _frames.firstObject.admittedAt > maxAge)) return nil;
    LDFrameTicket *ticket = [LDFrameTicket new];
    ticket.epoch = _epoch; ticket.pts = pts; ticket.admittedAt = now;
    [_frames addObject:ticket]; return ticket;
}
- (BOOL)contains:(LDFrameTicket *)ticket { return ticket && ticket.epoch == _epoch && [_frames containsObject:ticket]; }
- (void)releaseFrame:(LDFrameTicket *)ticket { if ([self contains:ticket]) [_frames removeObjectIdenticalTo:ticket]; }
- (void)ack:(uint64_t)pts {
    NSIndexSet *done = [_frames indexesOfObjectsPassingTest:^BOOL(LDFrameTicket *frame, NSUInteger i, BOOL *stop) {
        return frame.sent && frame.pts <= pts;
    }];
    [_frames removeObjectsAtIndexes:done];
}
@end
