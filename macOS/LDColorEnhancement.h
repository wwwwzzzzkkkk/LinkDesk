#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Owned and used only by the serial encoding queue.
@interface LDColorEnhancement : NSObject
// Caller owns the result. Returns NULL on failure so the original frame can pass through.
- (CVPixelBufferRef)copyEnhancedBuffer:(CVPixelBufferRef)source level:(NSInteger)level darkLevel:(NSInteger)darkLevel CF_RETURNS_RETAINED;
@end
