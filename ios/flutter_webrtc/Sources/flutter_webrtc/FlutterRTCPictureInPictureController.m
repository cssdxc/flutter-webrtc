#import "FlutterRTCPictureInPictureController.h"
#import "FlutterRTCPictureInPictureVideoView.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <WebRTC/WebRTC.h>

#if DEBUG
#define FLUTTER_RTC_PIP_LOG(...) NSLog(__VA_ARGS__)
#else
#define FLUTTER_RTC_PIP_LOG(...) do { } while (0)
#endif

API_AVAILABLE(ios(15.0))
@interface FlutterRTCPictureInPictureController () <AVPictureInPictureControllerDelegate>

@property(nonatomic, strong, nullable) AVPictureInPictureController* controller;
@property(nonatomic, strong, nullable) AVPictureInPictureVideoCallViewController* videoCallViewController;
@property(nonatomic, strong, nullable) FlutterRTCPictureInPictureVideoView* videoView;
@property(nonatomic, strong, nullable) RTCVideoTrack* videoTrack;
@property(nonatomic, weak, nullable) UIView* sourceView;
@property(nonatomic, strong, nullable) UIView* animationSourceView;
@property(nonatomic, assign) BOOL rendererAttached;
@property(nonatomic, assign) BOOL cleanupAfterStop;
@property(nonatomic, copy, nullable) void (^startCompletion)(NSError* _Nullable error);
@property(nonatomic, copy, nullable) void (^disposeCompletion)(void);
@property(nonatomic, copy, nullable) NSString* lastEvent;

- (BOOL)isPreparedForVideoTrack:(RTCVideoTrack*)videoTrack sourceView:(UIView*)sourceView;
- (void)attachRenderer;
- (void)detachRenderer;
- (void)startPictureInPictureWhenPossible:(AVPictureInPictureController*)controller
                         remainingAttempts:(NSInteger)remainingAttempts;
- (void)finishStartWithError:(NSError* _Nullable)error;
- (void)finishDispose;
- (void)notifyStateChanged:(BOOL)active;
- (NSString*)diagnosticDescription;
- (void)cleanup;
- (NSError*)errorWithMessage:(NSString*)message;

@end

@implementation FlutterRTCPictureInPictureController

- (BOOL)isActive {
  return self.controller != nil && self.controller.isPictureInPictureActive;
}

- (BOOL)isPreparedForVideoTrack:(RTCVideoTrack*)videoTrack sourceView:(UIView*)sourceView {
  return self.controller != nil && self.videoTrack == videoTrack && self.sourceView == sourceView;
}

- (NSError* _Nullable)prepareWithVideoTrack:(RTCVideoTrack*)videoTrack
                                  sourceView:(UIView*)sourceView {
  self.lastEvent = @"prepareRequested";
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP prepare: trackId=%@ mainThread=%d",
        videoTrack.trackId,
        NSThread.isMainThread);
  if (!AVPictureInPictureController.isPictureInPictureSupported) {
    return [self errorWithMessage:@"Picture in Picture is not supported on this device"];
  }

  if ([self isPreparedForVideoTrack:videoTrack sourceView:sourceView]) {
    self.lastEvent = self.controller.isPictureInPicturePossible
        ? @"prepared"
        : @"preparedWaitingForPossible";
    FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP already prepared: possible=%d active=%d",
          self.controller.isPictureInPicturePossible,
          self.controller.isPictureInPictureActive);
    return nil;
  }
  if (self.isActive) {
    return [self errorWithMessage:@"Picture in Picture is active with another source"];
  }
  if (self.startCompletion != nil) {
    return [self errorWithMessage:@"Picture in Picture is already starting"];
  }

  [self cleanup];
  self.sourceView = sourceView;

  AVPictureInPictureVideoCallViewController* contentViewController =
      [[AVPictureInPictureVideoCallViewController alloc] init];
  contentViewController.preferredContentSize = CGSizeMake(360, 640);
  contentViewController.view.backgroundColor = UIColor.blackColor;
  contentViewController.view.clipsToBounds = YES;

  FlutterRTCPictureInPictureVideoView* videoView =
      [[FlutterRTCPictureInPictureVideoView alloc]
          initWithFrame:contentViewController.view.bounds];
  videoView.translatesAutoresizingMaskIntoConstraints = NO;
  videoView.backgroundColor = UIColor.blackColor;
  videoView.clipsToBounds = YES;
  videoView.sampleBufferLayer.videoGravity = AVLayerVideoGravityResizeAspect;
  [contentViewController.view addSubview:videoView];
  [NSLayoutConstraint activateConstraints:@[
    [videoView.leadingAnchor constraintEqualToAnchor:contentViewController.view.leadingAnchor],
    [videoView.trailingAnchor constraintEqualToAnchor:contentViewController.view.trailingAnchor],
    [videoView.topAnchor constraintEqualToAnchor:contentViewController.view.topAnchor],
    [videoView.bottomAnchor constraintEqualToAnchor:contentViewController.view.bottomAnchor],
  ]];
  [contentViewController.view layoutIfNeeded];

  UIView* animationSourceView = [[UIView alloc] initWithFrame:CGRectZero];
  animationSourceView.translatesAutoresizingMaskIntoConstraints = NO;
  animationSourceView.backgroundColor = UIColor.clearColor;
  animationSourceView.userInteractionEnabled = NO;
  [sourceView addSubview:animationSourceView];
  NSLayoutConstraint* fillSourceHeight =
      [animationSourceView.heightAnchor constraintEqualToAnchor:sourceView.heightAnchor];
  fillSourceHeight.priority = 751;
  NSLayoutConstraint* fillSourceWidth =
      [animationSourceView.widthAnchor constraintEqualToAnchor:sourceView.widthAnchor];
  fillSourceWidth.priority = 750;
  [NSLayoutConstraint activateConstraints:@[
    [animationSourceView.centerXAnchor constraintEqualToAnchor:sourceView.centerXAnchor],
    [animationSourceView.centerYAnchor constraintEqualToAnchor:sourceView.centerYAnchor],
    [animationSourceView.widthAnchor constraintEqualToAnchor:animationSourceView.heightAnchor
                                                   multiplier:9.0 / 16.0],
    [animationSourceView.widthAnchor constraintLessThanOrEqualToAnchor:sourceView.widthAnchor],
    [animationSourceView.heightAnchor constraintLessThanOrEqualToAnchor:sourceView.heightAnchor],
    fillSourceHeight,
    fillSourceWidth,
  ]];
  [sourceView layoutIfNeeded];

  AVPictureInPictureControllerContentSource* contentSource =
      [[AVPictureInPictureControllerContentSource alloc]
          initWithActiveVideoCallSourceView:animationSourceView
                      contentViewController:contentViewController];
  AVPictureInPictureController* controller =
      [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
  controller.delegate = self;
  controller.canStartPictureInPictureAutomaticallyFromInline = YES;

  self.videoTrack = videoTrack;
  self.videoView = videoView;
  self.rendererAttached = NO;
  self.animationSourceView = animationSourceView;
  self.videoCallViewController = contentViewController;
  self.controller = controller;
  self.lastEvent = controller.isPictureInPicturePossible
      ? @"prepared"
      : @"preparedWaitingForPossible";
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP prepared: possible=%d active=%d sourceWindow=%d sourceBounds=%.0fx%.0f",
        controller.isPictureInPicturePossible,
        controller.isPictureInPictureActive,
        sourceView.window != nil,
        CGRectGetWidth(sourceView.bounds),
        CGRectGetHeight(sourceView.bounds));
  return nil;
}

- (void)startWithVideoTrack:(RTCVideoTrack*)videoTrack
                 sourceView:(UIView*)sourceView
                 completion:(void (^)(NSError* _Nullable error))completion {
  self.lastEvent = @"startRequested";
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP startWithVideoTrack: trackId=%@", videoTrack.trackId);
  if (!AVPictureInPictureController.isPictureInPictureSupported) {
    FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP unsupported by AVPictureInPictureController");
    completion([self errorWithMessage:@"Picture in Picture is not supported on this device"]);
    return;
  }

  if (self.isActive) {
    FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP already active");
    completion(nil);
    return;
  }
  if (self.startCompletion != nil) {
    FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP start already pending");
    completion([self errorWithMessage:@"Picture in Picture is already starting"]);
    return;
  }

  NSError* prepareError = [self prepareWithVideoTrack:videoTrack sourceView:sourceView];
  if (prepareError != nil) {
    self.lastEvent = [NSString stringWithFormat:@"prepareFailed:%@",
                                                prepareError.localizedDescription ?: @"unknown"];
    completion(prepareError);
    return;
  }
  self.startCompletion = completion;
  self.cleanupAfterStop = NO;
  [self attachRenderer];
  self.lastEvent = @"startUsingPreparedController";
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP start using prepared controller: possible=%d active=%d mainThread=%d",
        self.controller.isPictureInPicturePossible,
        self.controller.isPictureInPictureActive,
        NSThread.isMainThread);
  [self startPictureInPictureWhenPossible:self.controller remainingAttempts:50];
}

- (void)updateVideoTrack:(RTCVideoTrack*)videoTrack {
  if (videoTrack == nil || self.videoTrack == videoTrack) {
    return;
  }

  BOOL shouldAttach = self.rendererAttached;
  [self detachRenderer];
  self.videoTrack = videoTrack;
  if (shouldAttach) {
    [self attachRenderer];
  }
  self.lastEvent = @"trackUpdated";
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP track updated: trackId=%@ attached=%d",
        videoTrack.trackId,
        self.rendererAttached);
}

- (void)attachRenderer {
  if (self.rendererAttached || self.videoTrack == nil || self.videoView == nil) {
    return;
  }
  [self.videoTrack addRenderer:self.videoView];
  self.rendererAttached = YES;
}

- (void)detachRenderer {
  if (!self.rendererAttached || self.videoTrack == nil || self.videoView == nil) {
    return;
  }
  [self.videoTrack removeRenderer:self.videoView];
  self.rendererAttached = NO;
}

- (void)startPictureInPictureWhenPossible:(AVPictureInPictureController*)controller
                         remainingAttempts:(NSInteger)remainingAttempts {
  if (self.controller != controller) {
    return;
  }
  if (controller.isPictureInPictureActive) {
    self.lastEvent = @"activeObserved";
    [self finishStartWithError:nil];
    return;
  }
  if (controller.isPictureInPicturePossible) {
    self.lastEvent = @"callingStartPictureInPicture";
    FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP starting after content source became ready");
    [controller startPictureInPicture];
    return;
  }
  if (remainingAttempts <= 0) {
    NSString* message = [NSString stringWithFormat:
        @"Picture in Picture did not become possible (%@)",
        [self diagnosticDescription]];
    FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP start timed out: %@", message);
    self.lastEvent = [NSString stringWithFormat:@"possibleTimedOut:%@", message];
    [self finishStartWithError:[self errorWithMessage:message]];
    [self cleanup];
    return;
  }

  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    [weakSelf startPictureInPictureWhenPossible:controller
                               remainingAttempts:remainingAttempts - 1];
  });
}

- (void)finishStartWithError:(NSError* _Nullable)error {
  void (^completion)(NSError* _Nullable) = self.startCompletion;
  self.startCompletion = nil;
  if (completion != nil) {
    completion(error);
  }
}

- (void)finishDispose {
  void (^completion)(void) = self.disposeCompletion;
  self.disposeCompletion = nil;
  if (completion != nil) {
    completion();
  }
}

- (void)notifyStateChanged:(BOOL)active {
  FlutterRTCPictureInPictureStateChangedHandler handler = self.stateChangedHandler;
  if (handler != nil) {
    handler(active);
  }
}

- (NSString*)diagnosticDescription {
  RTCAudioSession* audioSession = [RTCAudioSession sharedInstance];
  UIView* sourceView = self.sourceView;
  return [NSString stringWithFormat:
      @"possible=%d active=%d sourceWindow=%d sourceBounds=%.0fx%.0f audioActive=%d category=%@ mode=%@",
      self.controller.isPictureInPicturePossible,
      self.controller.isPictureInPictureActive,
      sourceView.window != nil,
      CGRectGetWidth(sourceView.bounds),
      CGRectGetHeight(sourceView.bounds),
      audioSession.isActive,
      audioSession.category,
      audioSession.mode];
}

- (NSDictionary<NSString*, id>*)debugState {
  RTCAudioSession* audioSession = [RTCAudioSession sharedInstance];
  UIView* sourceView = self.sourceView;
  AVPictureInPictureController* controller = self.controller;
  UIApplicationState applicationState = UIApplication.sharedApplication.applicationState;
  NSString* applicationStateName = @"unknown";
  if (applicationState == UIApplicationStateActive) {
    applicationStateName = @"active";
  } else if (applicationState == UIApplicationStateInactive) {
    applicationStateName = @"inactive";
  } else if (applicationState == UIApplicationStateBackground) {
    applicationStateName = @"background";
  }

  return @{
    @"event" : self.lastEvent ?: @"idle",
    @"appState" : applicationStateName,
    @"controllerCreated" : @(controller != nil),
    @"prepared" : @(controller != nil && self.videoTrack != nil && sourceView != nil),
    @"trackId" : self.videoTrack.trackId ?: @"-",
    @"possible" : @(controller.isPictureInPicturePossible),
    @"active" : @(controller.isPictureInPictureActive),
    @"suspended" : @(controller.isPictureInPictureSuspended),
    @"sourceClass" : sourceView == nil ? @"-" : NSStringFromClass(sourceView.class),
    @"sourceInWindow" : @(sourceView.window != nil),
    @"sourceHidden" : @(sourceView.hidden),
    @"sourceAlpha" : @(sourceView.alpha),
    @"sourceWidth" : @(CGRectGetWidth(sourceView.bounds)),
    @"sourceHeight" : @(CGRectGetHeight(sourceView.bounds)),
    @"animationSourceInWindow" : @(self.animationSourceView.window != nil),
    @"animationSourceWidth" : @(CGRectGetWidth(self.animationSourceView.bounds)),
    @"animationSourceHeight" : @(CGRectGetHeight(self.animationSourceView.bounds)),
    @"audioActive" : @(audioSession.isActive),
    @"audioCategory" : audioSession.category ?: @"-",
    @"audioMode" : audioSession.mode ?: @"-",
    @"videoGravity" : self.videoView.sampleBufferLayer.videoGravity ?: @"-",
    @"renderer" : self.videoView == nil ? @{} : [self.videoView debugState],
  };
}

- (void)stop {
  self.lastEvent = @"stopRequested";
  if (self.controller == nil) {
    [self finishStartWithError:[self errorWithMessage:@"Picture in Picture was stopped"]];
    return;
  }

  if (self.controller.isPictureInPictureActive) {
    self.cleanupAfterStop = NO;
    [self.controller stopPictureInPicture];
  } else if (self.startCompletion != nil) {
    [self finishStartWithError:[self errorWithMessage:@"Picture in Picture was stopped"]];
    [self cleanup];
  }
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController*)pictureInPictureController {
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP did stop");
  [self finishStartWithError:nil];
  [self detachRenderer];
  [self notifyStateChanged:NO];
  if (self.cleanupAfterStop) {
    self.lastEvent = @"didStopAndCleanup";
    [self cleanup];
    [self finishDispose];
    return;
  }

  self.lastEvent = @"preparedAfterStop";
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP retained controller after stop: possible=%d sourceWindow=%d",
        self.controller.isPictureInPicturePossible,
        self.sourceView.window != nil);
}

- (void)pictureInPictureControllerWillStartPictureInPicture:
    (AVPictureInPictureController*)pictureInPictureController {
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP will start");
  self.lastEvent = @"willStart";
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController*)pictureInPictureController {
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP did start");
  self.lastEvent = @"didStart";
  [self finishStartWithError:nil];
  [self notifyStateChanged:YES];
}

- (void)pictureInPictureController:
            (AVPictureInPictureController*)pictureInPictureController
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:
        (void (^)(BOOL restored))completionHandler {
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP restore user interface requested");
  FlutterRTCPictureInPictureRestoreHandler handler =
      self.restoreUserInterfaceHandler;
  if (handler == nil) {
    completionHandler(NO);
    return;
  }
  handler(completionHandler);
}

- (void)pictureInPictureController:
            (AVPictureInPictureController*)pictureInPictureController
    failedToStartPictureInPictureWithError:(NSError*)error {
  FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP failed to start: %@", error.localizedDescription);
  self.lastEvent = [NSString stringWithFormat:@"failed:%@",
                                              error.localizedDescription ?: @"unknown"];
  [self finishStartWithError:error];
  [self detachRenderer];
  [self notifyStateChanged:NO];
  [self cleanup];
}

- (void)disposeWithCompletion:(void (^)(void))completion {
  if (self.disposeCompletion != nil) {
    void (^existingCompletion)(void) = self.disposeCompletion;
    self.disposeCompletion = ^{
      existingCompletion();
      completion();
    };
    return;
  }

  self.disposeCompletion = completion;
  [self finishStartWithError:[self errorWithMessage:@"Picture in Picture was disposed"]];
  if (self.controller == nil || !self.controller.isPictureInPictureActive) {
    [self cleanup];
    [self finishDispose];
    return;
  }

  self.cleanupAfterStop = YES;
  self.lastEvent = @"disposeWaitingForStop";
  AVPictureInPictureController* disposingController = self.controller;
  [disposingController stopPictureInPicture];

  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf == nil ||
        strongSelf.controller != disposingController ||
        strongSelf.disposeCompletion == nil) {
      return;
    }
    FLUTTER_RTC_PIP_LOG(@"FlutterWebRTC PiP dispose stop timed out; forcing cleanup");
    strongSelf.lastEvent = @"disposeStopTimedOut";
    [strongSelf cleanup];
    [strongSelf finishDispose];
  });
}

- (void)disposeImmediately {
  [self cleanup];
  [self finishDispose];
}

- (void)cleanup {
  [self detachRenderer];
  self.controller.delegate = nil;
  [self.animationSourceView removeFromSuperview];
  [self.videoView removeFromSuperview];
  self.controller = nil;
  self.videoCallViewController = nil;
  self.videoView = nil;
  self.videoTrack = nil;
  self.sourceView = nil;
  self.animationSourceView = nil;
  self.cleanupAfterStop = NO;
}

- (NSError*)errorWithMessage:(NSString*)message {
  return [NSError errorWithDomain:@"FlutterWebRTCPictureInPicture"
                             code:0
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

@end
