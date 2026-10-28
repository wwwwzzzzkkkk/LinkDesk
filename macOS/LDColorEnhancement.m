#import "LDColorEnhancement.h"
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>

@implementation LDColorEnhancement {
    CIContext *_context;
    CIColorKernel *_darkKernel;
    CVPixelBufferPoolRef _pool;
    OSType _format;
    size_t _width, _height;
}
- (void)dealloc { if (_pool) CVPixelBufferPoolRelease(_pool); }
- (CVPixelBufferRef)copyEnhancedBuffer:(CVPixelBufferRef)source level:(NSInteger)level darkLevel:(NSInteger)darkLevel {
    if (!source || level < 0 || level > 2 || darkLevel < 0 || darkLevel > 2) return NULL;
    OSType format = CVPixelBufferGetPixelFormatType(source);
    BOOL hdr = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    if (!hdr && format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) return NULL;
    if (!hdr) darkLevel = 0;
    if (level == 0 && darkLevel == 0) return NULL;
    size_t width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source);
    if (!_context) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        CGColorSpaceRef working = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
        if (device && working) _context = [CIContext contextWithMTLDevice:device options:@{kCIContextWorkingColorSpace:(__bridge id)working, kCIContextCacheIntermediates:@NO}];
        if (working) CGColorSpaceRelease(working);
        if (!_context) return NULL;
    }
    if (!_pool || _format != format || _width != width || _height != height) {
        if (_pool) { CVPixelBufferPoolRelease(_pool); _pool = NULL; }
        NSDictionary *attributes = @{(id)kCVPixelBufferPixelFormatTypeKey:@(format), (id)kCVPixelBufferWidthKey:@(width), (id)kCVPixelBufferHeightKey:@(height), (id)kCVPixelBufferIOSurfacePropertiesKey:@{}, (id)kCVPixelBufferMetalCompatibilityKey:@YES};
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &_pool) != kCVReturnSuccess) return NULL;
        _format=format; _width=width; _height=height;
    }
    CVPixelBufferRef output = NULL;
    NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey:@10};
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, _pool, (__bridge CFDictionaryRef)limit, &output) != kCVReturnSuccess) return NULL;
    CVBufferRemoveAllAttachments(output);
    CVBufferPropagateAttachments(source, output);
    CGColorSpaceRef color = CGColorSpaceCreateWithName(hdr ? kCGColorSpaceITUR_2100_PQ : kCGColorSpaceITUR_709);
    if (!color) { CVPixelBufferRelease(output); return NULL; }
    @autoreleasepool {
        CIImage *image = [CIImage imageWithCVPixelBuffer:source options:@{kCIImageColorSpace:(__bridge id)color}];
        CIImage *result = image;
        if (level > 0) {
            CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
            [filter setValue:result forKey:kCIInputImageKey];
            [filter setValue:@(level == 1 ? 1.03 : 1.06) forKey:kCIInputSaturationKey];
            result = filter.outputImage;
        }
        if (darkLevel > 0 && result) {
            // Linear-light luminance: preserve hue, zero, and values at or
            // above SDR reference white. Smoothly lower only the shadows.
            if (!_darkKernel) _darkKernel = [CIColorKernel kernelWithString:@"kernel vec4 shadows(__sample p, float amount) { float y = dot(p.rgb, vec3(0.2627, 0.6780, 0.0593)); float t = clamp(1.0 - max(y, 0.0), 0.0, 1.0); float factor = 1.0 - amount * t * t; return vec4(p.rgb * factor, p.a); }"];
            if (_darkKernel) result = [_darkKernel applyWithExtent:result.extent arguments:@[result, @(darkLevel == 1 ? 0.30 : 0.50)]];
        }
        if (!result || (darkLevel > 0 && !_darkKernel)) { CGColorSpaceRelease(color); CVPixelBufferRelease(output); return NULL; }
        [_context render:result toCVPixelBuffer:output bounds:CGRectMake(0, 0, width, height) colorSpace:color];
    }
    CGColorSpaceRelease(color);
    return output;
}
@end
