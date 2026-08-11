#import "FlutterRTCPictureInPictureI420Converter.h"

@interface FlutterRTCPictureInPictureI420Converter ()
@property(nonatomic, assign) vImage_YpCbCrToARGB* conversionInfo;
@property(nonatomic, assign) CVPixelBufferPoolRef pixelBufferPool;
@property(nonatomic, assign) size_t poolWidth;
@property(nonatomic, assign) size_t poolHeight;
@end

@implementation FlutterRTCPictureInPictureI420Converter

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    vImage_YpCbCrPixelRange pixelRange = {16, 128, 235, 240, 255, 0, 255, 0};
    _conversionInfo = malloc(sizeof(vImage_YpCbCrToARGB));
    vImage_Error error = vImageConvert_YpCbCrToARGB_GenerateConversion(
        kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
        &pixelRange,
        _conversionInfo,
        kvImage420Yp8_Cb8_Cr8,
        kvImageARGB8888,
        kvImageNoFlags);
    if (error != kvImageNoError) {
      free(_conversionInfo);
      _conversionInfo = NULL;
    }
  }
  return self;
}

- (CVPixelBufferRef)createPixelBufferFromI420:(RTCI420Buffer*)buffer {
  if (self.conversionInfo == NULL) {
    return NULL;
  }
  if (self.pixelBufferPool == NULL || self.poolWidth != buffer.width ||
      self.poolHeight != buffer.height) {
    [self createPoolWithWidth:buffer.width height:buffer.height];
  }
  if (self.pixelBufferPool == NULL) {
    return NULL;
  }

  CVPixelBufferRef pixelBuffer = NULL;
  CVReturn status = CVPixelBufferPoolCreatePixelBuffer(
      kCFAllocatorDefault, self.pixelBufferPool, &pixelBuffer);
  if (status != kCVReturnSuccess || pixelBuffer == NULL) {
    return NULL;
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  vImage_Buffer yBuffer = {
      .data = (void*)buffer.dataY,
      .height = buffer.height,
      .width = buffer.width,
      .rowBytes = buffer.strideY,
  };
  vImage_Buffer uBuffer = {
      .data = (void*)buffer.dataU,
      .height = buffer.chromaHeight,
      .width = buffer.chromaWidth,
      .rowBytes = buffer.strideU,
  };
  vImage_Buffer vBuffer = {
      .data = (void*)buffer.dataV,
      .height = buffer.chromaHeight,
      .width = buffer.chromaWidth,
      .rowBytes = buffer.strideV,
  };
  vImage_Buffer destination = {
      .data = CVPixelBufferGetBaseAddress(pixelBuffer),
      .height = buffer.height,
      .width = buffer.width,
      .rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer),
  };
  uint8_t permuteMap[4] = {3, 2, 1, 0};
  vImage_Error error = vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(
      &yBuffer,
      &uBuffer,
      &vBuffer,
      &destination,
      self.conversionInfo,
      permuteMap,
      255,
      kvImageNoFlags);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

  if (error != kvImageNoError) {
    CVPixelBufferRelease(pixelBuffer);
    return NULL;
  }
  return pixelBuffer;
}

- (void)createPoolWithWidth:(size_t)width height:(size_t)height {
  if (self.pixelBufferPool != NULL) {
    CVPixelBufferPoolRelease(self.pixelBufferPool);
    self.pixelBufferPool = NULL;
  }
  self.poolWidth = width;
  self.poolHeight = height;
  NSDictionary* attributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferWidthKey : @(width),
    (id)kCVPixelBufferHeightKey : @(height),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
  };
  CVPixelBufferPoolCreate(kCFAllocatorDefault,
                          NULL,
                          (__bridge CFDictionaryRef)attributes,
                          &_pixelBufferPool);
}

- (void)dealloc {
  if (_conversionInfo != NULL) {
    free(_conversionInfo);
    _conversionInfo = NULL;
  }
  if (_pixelBufferPool != NULL) {
    CVPixelBufferPoolRelease(_pixelBufferPool);
    _pixelBufferPool = NULL;
  }
}

@end
