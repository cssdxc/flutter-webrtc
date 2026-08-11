#import "FlutterRTCPictureInPictureVideoView.h"

#import "FlutterRTCPictureInPictureI420Converter.h"
#import <WebRTC/WebRTC.h>

@protocol FlutterRTCSampleBufferRendering <AVQueuedSampleBufferRendering>
@property(nonatomic, readonly) BOOL requiresFlushToResumeDecoding;
@end

@interface AVSampleBufferDisplayLayer () <FlutterRTCSampleBufferRendering>
@end

API_AVAILABLE(ios(17.0))
@interface AVSampleBufferVideoRenderer () <FlutterRTCSampleBufferRendering>
@end

@interface FlutterRTCPictureInPictureVideoView ()
@property(nonatomic, strong) FlutterRTCPictureInPictureI420Converter* i420Converter;
@property(nonatomic, strong) id<FlutterRTCSampleBufferRendering> renderer;
@property(nonatomic, assign) RTCVideoRotation currentRotation;
@property(atomic, assign) NSUInteger receivedFrameCount;
@property(atomic, assign) NSUInteger enqueuedFrameCount;
@property(atomic, assign) NSUInteger droppedFrameCount;
@property(atomic, assign) NSInteger lastFrameWidth;
@property(atomic, assign) NSInteger lastFrameHeight;
@property(atomic, copy, nullable) NSString* lastDecodeError;
@end

@implementation FlutterRTCPictureInPictureVideoView

+ (Class)layerClass {
  return [AVSampleBufferDisplayLayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self != nil) {
    _currentRotation = -1;
    _i420Converter = [[FlutterRTCPictureInPictureI420Converter alloc] init];
    self.sampleBufferLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    if (@available(iOS 17.0, *)) {
      _renderer = (id<FlutterRTCSampleBufferRendering>)self.sampleBufferLayer.sampleBufferRenderer;
    } else {
      _renderer = (id<FlutterRTCSampleBufferRendering>)self.sampleBufferLayer;
    }
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(sampleBufferLayerFailedToDecode:)
               name:AVSampleBufferDisplayLayerFailedToDecodeNotification
             object:self.sampleBufferLayer];
  }
  return self;
}

- (AVSampleBufferDisplayLayer*)sampleBufferLayer {
  return (AVSampleBufferDisplayLayer*)self.layer;
}

- (void)setSize:(CGSize)size {
}

- (void)renderFrame:(RTCVideoFrame*)frame {
  if (frame == nil) {
    return;
  }
  self.receivedFrameCount += 1;
  self.lastFrameWidth = frame.width;
  self.lastFrameHeight = frame.height;
  CMSampleBufferRef sampleBuffer = [self createSampleBufferFromFrame:frame];
  if (sampleBuffer == NULL) {
    self.droppedFrameCount += 1;
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.renderer.requiresFlushToResumeDecoding) {
      [self.renderer flush];
    }
    if (self.renderer.readyForMoreMediaData) {
      [self updateTransformForRotation:frame.rotation];
      [self.renderer enqueueSampleBuffer:sampleBuffer];
      self.enqueuedFrameCount += 1;
    } else {
      self.droppedFrameCount += 1;
    }
    CFRelease(sampleBuffer);
  });
}

- (void)sampleBufferLayerFailedToDecode:(NSNotification*)notification {
  NSError* error = notification.userInfo[
      AVSampleBufferDisplayLayerFailedToDecodeNotificationErrorKey];
  self.lastDecodeError = error.localizedDescription ?: @"unknown";
}

- (NSDictionary<NSString*, id>*)debugState {
  return @{
    @"receivedFrames" : @(self.receivedFrameCount),
    @"enqueuedFrames" : @(self.enqueuedFrameCount),
    @"droppedFrames" : @(self.droppedFrameCount),
    @"lastFrameWidth" : @(self.lastFrameWidth),
    @"lastFrameHeight" : @(self.lastFrameHeight),
    @"rotation" : @(self.currentRotation),
    @"readyForMoreMediaData" : @(self.renderer.readyForMoreMediaData),
    @"requiresFlush" : @(self.renderer.requiresFlushToResumeDecoding),
    @"decodeError" : self.lastDecodeError ?: @"-",
  };
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (CMSampleBufferRef)createSampleBufferFromFrame:(RTCVideoFrame*)frame {
  CVPixelBufferRef pixelBuffer = [self createPixelBufferFromFrame:frame];
  if (pixelBuffer == NULL) {
    return NULL;
  }

  CMVideoFormatDescriptionRef format = NULL;
  OSStatus formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(
      kCFAllocatorDefault, pixelBuffer, &format);
  if (formatStatus != noErr || format == NULL) {
    CVPixelBufferRelease(pixelBuffer);
    return NULL;
  }

  CMSampleTimingInfo timing = {
      .duration = kCMTimeInvalid,
      .presentationTimeStamp = CMTimeMake(frame.timeStamp, 90000),
      .decodeTimeStamp = kCMTimeInvalid,
  };
  CMSampleBufferRef sampleBuffer = NULL;
  OSStatus sampleStatus = CMSampleBufferCreateForImageBuffer(
      kCFAllocatorDefault,
      pixelBuffer,
      true,
      NULL,
      NULL,
      format,
      &timing,
      &sampleBuffer);
  CFRelease(format);
  CVPixelBufferRelease(pixelBuffer);
  if (sampleStatus != noErr || sampleBuffer == NULL) {
    return NULL;
  }

  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
  if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
    CFMutableDictionaryRef attachment =
        (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(
        attachment, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  }
  return sampleBuffer;
}

- (CVPixelBufferRef)createPixelBufferFromFrame:(RTCVideoFrame*)frame {
  if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    CVPixelBufferRef pixelBuffer = ((RTCCVPixelBuffer*)frame.buffer).pixelBuffer;
    CVPixelBufferRetain(pixelBuffer);
    return pixelBuffer;
  }
  return [self.i420Converter createPixelBufferFromI420:[frame.buffer toI420]];
}

- (void)updateTransformForRotation:(RTCVideoRotation)rotation {
  if (self.currentRotation == rotation) {
    return;
  }
  self.currentRotation = rotation;
  CGFloat scale = 1;
  if (rotation == RTCVideoRotation_90 || rotation == RTCVideoRotation_270) {
    CGSize size = self.bounds.size;
    if (size.width > 0) {
      scale = size.height / size.width;
    }
  }
  self.sampleBufferLayer.transform = CATransform3DConcat(
      CATransform3DMakeRotation(rotation / 180.0 * M_PI, 0, 0, 1),
      CATransform3DMakeScale(scale, scale, 1));
}

@end
