#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import "LDColorEnhancement.h"
int main(void) { @autoreleasepool {
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},(id)kCVPixelBufferMetalCompatibilityKey:@YES};
    for (int hdr=0;hdr<2;hdr++) {
      OSType f=hdr?kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
      CVPixelBufferRef src=NULL; if(CVPixelBufferCreate(NULL,2880,1920,f,(__bridge CFDictionaryRef)attrs,&src)) return 1;
      CGColorSpaceRef cs=CGColorSpaceCreateWithName(hdr?kCGColorSpaceITUR_2100_PQ:kCGColorSpaceITUR_709);
      CVBufferSetAttachment(src,kCVImageBufferColorPrimariesKey,hdr?kCVImageBufferColorPrimaries_ITU_R_2020:kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(src,kCVImageBufferTransferFunctionKey,hdr?kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ:kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(src,kCVImageBufferYCbCrMatrixKey,hdr?kCVImageBufferYCbCrMatrix_ITU_R_2020:kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
      CIImage *image=[[CIImage imageWithColor:[CIColor colorWithRed:.50 green:.20 blue:.10]] imageByCroppingToRect:CGRectMake(0,0,2880,1920)];
      [[CIContext context] render:image toCVPixelBuffer:src bounds:image.extent colorSpace:cs];
      LDColorEnhancement *effect=[LDColorEnhancement new];
      CVPixelBufferRef output=[effect copyEnhancedBuffer:src level:1 darkLevel:0]; if(!output) return 2;
      CVPixelBufferLockBaseAddress(src,kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(output,kCVPixelBufferLock_ReadOnly);
      int before=hdr?(*(uint16_t*)CVPixelBufferGetBaseAddressOfPlane(src,1)>>6):*(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(src,1);
      int after=hdr?(*(uint16_t*)CVPixelBufferGetBaseAddressOfPlane(output,1)>>6):*(uint8_t*)CVPixelBufferGetBaseAddressOfPlane(output,1);
      CVPixelBufferUnlockBaseAddress(output,kCVPixelBufferLock_ReadOnly);CVPixelBufferUnlockBaseAddress(src,kCVPixelBufferLock_ReadOnly);
      printf("%s chroma before=%d after=%d\n",hdr?"HDR":"SDR",before,after); if(before==after) return 3;
      CFTypeRef attachment=CVBufferCopyAttachment(output,kCVImageBufferTransferFunctionKey,NULL); if(!attachment) return 4; CFRelease(attachment);
      CFRelease(output);CFRelease(src);CGColorSpaceRelease(cs);
    }
    // Neutral greys, including black and near-black, must not be lifted by saturation.
    CGColorSpaceRef pq=CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
    CGColorSpaceRef linear=CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
    CIContext *context=[CIContext context]; LDColorEnhancement *effect=[LDColorEnhancement new];
    for (NSNumber *level in @[@0, @0.001, @0.01, @0.05, @0.18, @1.0, @2.0, @4.0]) {
      CVPixelBufferRef source=NULL;
      if (CVPixelBufferCreate(NULL,256,256,kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,(__bridge CFDictionaryRef)attrs,&source)) return 5;
      CVBufferSetAttachment(source,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(source,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(source,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_2020,kCVAttachmentMode_ShouldPropagate);
      CGFloat v=level.doubleValue;
      CIImage *gray=[[CIImage imageWithColor:[CIColor colorWithRed:v green:v blue:v alpha:1 colorSpace:linear]] imageByCroppingToRect:CGRectMake(0,0,256,256)];
      [context render:gray toCVPixelBuffer:source bounds:gray.extent colorSpace:pq];
      for (NSInteger preset=1;preset<=2;preset++) {
        CVPixelBufferRef result=[effect copyEnhancedBuffer:source level:preset darkLevel:0]; if(!result) return 6;
        CVPixelBufferLockBaseAddress(source,kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(result,kCVPixelBufferLock_ReadOnly);
        int before=*(uint16_t*)CVPixelBufferGetBaseAddressOfPlane(source,0)>>6;
        int after=*(uint16_t*)CVPixelBufferGetBaseAddressOfPlane(result,0)>>6;
        CVPixelBufferUnlockBaseAddress(result,kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
        CFRelease(result);
        if(abs(before-after)>1 || (v==0 && after!=64)) return 7;
        printf("HDR gray %.3f preset %ld: %d -> %d\n",v,(long)preset,before,after);
      }
      for (NSInteger preset=1;preset<=2;preset++) {
        CVPixelBufferRef result=[effect copyEnhancedBuffer:source level:0 darkLevel:preset]; if(!result) return 8;
        CVPixelBufferLockBaseAddress(source,kCVPixelBufferLock_ReadOnly); CVPixelBufferLockBaseAddress(result,kCVPixelBufferLock_ReadOnly);
        int before=*(uint16_t*)CVPixelBufferGetBaseAddressOfPlane(source,0)>>6;
        int after=*(uint16_t*)CVPixelBufferGetBaseAddressOfPlane(result,0)>>6;
        CVPixelBufferUnlockBaseAddress(result,kCVPixelBufferLock_ReadOnly); CVPixelBufferUnlockBaseAddress(source,kCVPixelBufferLock_ReadOnly);
        CFRelease(result); printf("HDR shadows %.3f preset %ld: %d -> %d\n",v,(long)preset,before,after);
        if(after>before+1 || (v==0 && after!=64) || (v>=1 && abs(before-after)>1)) return 9;
        if(v>0 && v<1 && after>=before) return 10;
      }
      CFRelease(source);
    }
    CGColorSpaceRelease(linear); CGColorSpaceRelease(pq); return 0;
}}
