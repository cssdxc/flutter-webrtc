#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^FlutterRTCPictureInPictureRestoreCompletion)(BOOL restored);
typedef void (^FlutterRTCPictureInPictureRestoreHandler)(
    FlutterRTCPictureInPictureRestoreCompletion completion);
typedef void (^FlutterRTCPictureInPictureStateChangedHandler)(BOOL active);

API_AVAILABLE(ios(15.0))
@interface FlutterRTCPictureInPictureController : NSObject

@property(nonatomic, copy, nullable)
    FlutterRTCPictureInPictureRestoreHandler restoreUserInterfaceHandler;
@property(nonatomic, copy, nullable)
    FlutterRTCPictureInPictureStateChangedHandler stateChangedHandler;

- (BOOL)isActive;
- (nullable NSError*)prepareWithVideoTrack:(RTCVideoTrack*)videoTrack
                                 sourceView:(UIView*)sourceView;
- (void)startWithVideoTrack:(RTCVideoTrack*)videoTrack
                 sourceView:(UIView*)sourceView
                 completion:(void (^)(NSError* _Nullable error))completion;
- (void)updateVideoTrack:(RTCVideoTrack*)videoTrack;
- (NSDictionary<NSString*, id>*)debugState;
- (void)stop;
- (void)disposeWithCompletion:(void (^)(void))completion;
- (void)disposeImmediately;

@end

NS_ASSUME_NONNULL_END
