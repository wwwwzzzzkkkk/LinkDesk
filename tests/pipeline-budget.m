#import "../macOS/LDPipelineBudget.h"
#import <VideoToolbox/VideoToolbox.h>
#import <unistd.h>
#include <assert.h>

int main(int argc, const char *argv[]) {
    int fps = argc > 1 ? atoi(argv[1]) : 144;
    assert(fps == 60 || fps == 120 || fps == 144);
    NSUInteger limit = fps == 60 ? 2 : (NSUInteger)ceil(fps * 0.06);
    @autoreleasepool {
        LDPipelineBudget *budget = [LDPipelineBudget new];
        [budget reset:1];
        LDFrameTicket *first = [budget reserve:1 now:0 limit:2];
        LDFrameTicket *second = [budget reserve:2 now:0 limit:2];
        assert(![budget reserve:3 now:0 limit:2]); // Includes work not yet encoded/sent.
        [budget ack:2]; assert(budget.frames.count == 2); // ACK cannot retire unsent work.
        first.sent = YES; [budget ack:1]; assert(budget.frames.count == 1);
        LDFrameTicket *recovery=[budget reserve:3 now:0.061 limit:2];
        assert(recovery); // One old frame cannot halt all new work.
        assert(![budget reserve:4 now:0.062 limit:9]); // Age pressure still bounds backlog to two.
        [budget releaseFrame:recovery];
        [budget releaseFrame:second]; [budget releaseFrame:second];
        assert(budget.frames.count == 0); // Error/drop release is idempotent.
        LDFrameTicket *old = [budget reserve:4 now:1 limit:2];
        [budget reset:2];
        LDFrameTicket *fresh = [budget reserve:4 now:1 limit:2];
        assert(![budget contains:old]); [budget releaseFrame:old];
        assert([budget contains:fresh]);
        [budget reset:3]; assert(budget.frames.count == 0); // Stop invalidates callbacks.

        // Repeated long ACK stalls must cap work and recover without reconnecting.
        for (int cycle = 0; cycle < 1000; ++cycle) {
            double now = cycle;
            for (int frame = 0; frame < 100; ++frame) {
                LDFrameTicket *t = [budget reserve:frame + 1 now:now + frame * 0.007 limit:9];
                if (t) t.sent = YES;
                assert(budget.frames.count <= 9);
            }
            [budget ack:100]; assert(budget.frames.count == 0);
        }

        // Exercise the real M1 hardware encoder with the same nine-frame budget
        // and block callback API. This does not access recording permissions.
        VTCompressionSessionRef encoder = NULL;
        NSMutableDictionary *spec = [@{(__bridge NSString *)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES} mutableCopy];
        if (fps == 60) spec[(__bridge NSString *)kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = @YES;
        assert(VTCompressionSessionCreate(NULL, 2880, 1920, fps == 60 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            (__bridge CFDictionaryRef)spec, NULL, NULL, NULL, NULL, &encoder) == noErr);
        VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
        VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
        VTSessionSetProperty(encoder, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@(fps));
        VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@64800000);
        VTCompressionSessionPrepareToEncodeFrames(encoder);
        CVPixelBufferRef pixel = NULL;
        assert(CVPixelBufferCreate(NULL, 2880, 1920, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            (__bridge CFDictionaryRef)@{(__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}}, &pixel) == kCVReturnSuccess);
        CVPixelBufferLockBaseAddress(pixel, 0);
        for (size_t plane = 0; plane < 2; ++plane)
            memset(CVPixelBufferGetBaseAddressOfPlane(pixel, plane), plane ? 128 : 32,
                CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane));
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        NSLock *lock = [NSLock new];
        __block NSUInteger output = 0, dropped = 0, highWater = 0;
        for (int i = 1; i <= fps * 5; ++i) {
            [lock lock];
            LDFrameTicket *ticket = [budget reserve:i now:NSProcessInfo.processInfo.systemUptime limit:limit];
            highWater = MAX(highWater, budget.frames.count); [lock unlock];
            if (ticket) {
                VTEncodeInfoFlags info = 0;
                OSStatus result = VTCompressionSessionEncodeFrameWithOutputHandler(encoder, pixel, CMTimeMake(i, fps), CMTimeMake(1, fps), NULL, &info,
                    ^(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
                        [lock lock];
                        if (status == noErr && sample && !(flags & kVTEncodeInfo_FrameDropped)) {
                            output++; ticket.sent = YES; [budget ack:ticket.pts];
                        } else { dropped++; [budget releaseFrame:ticket]; }
                        [lock unlock];
                    });
                if (result != noErr || (info & kVTEncodeInfo_FrameDropped)) {
                    [lock lock]; [budget releaseFrame:ticket]; [lock unlock];
                }
            }
            usleep(1000000 / fps);
        }
        VTCompressionSessionCompleteFrames(encoder, kCMTimeInvalid);
        VTCompressionSessionInvalidate(encoder); CFRelease(encoder); CVPixelBufferRelease(pixel);
        assert(output > 100 && highWater <= limit && budget.frames.count == 0);
        NSLog(@"PIPELINE_TEST PASS fps=%d outputs=%lu dropped=%lu highWater=%lu remaining=%lu", fps, output, dropped, highWater, budget.frames.count);
    }
    return 0;
}
