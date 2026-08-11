#import <Accelerate/Accelerate.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <WebRTC/WebRTC.h>

@interface FlutterRTCPictureInPictureI420Converter : NSObject

- (CVPixelBufferRef)createPixelBufferFromI420:(RTCI420Buffer*)buffer CF_RETURNS_RETAINED;

@end
