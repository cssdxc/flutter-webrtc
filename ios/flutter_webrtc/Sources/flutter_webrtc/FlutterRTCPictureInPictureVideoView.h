#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/RTCVideoRenderer.h>

@interface FlutterRTCPictureInPictureVideoView : UIView <RTCVideoRenderer>

@property(nonatomic, readonly) AVSampleBufferDisplayLayer* sampleBufferLayer;

- (NSDictionary<NSString*, id>*)debugState;

@end
