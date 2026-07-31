#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <WebRTC/WebRTC.h>

@interface FlutterRTCAudioSink : NSObject

@property (nonatomic, copy) void (^bufferCallback)(CMSampleBufferRef);
@property (nonatomic) CMAudioFormatDescriptionRef format;

- (instancetype) initWithAudioTrack:(RTCAudioTrack*)audio;

// Device motion 录像需要从本地采集处理链获取麦克风 PCM；Viewer 录像仍从
// 远端音轨获取播放 PCM，两个入口不能混用同一个 renderer 接入方式。
- (instancetype) initWithAudioTrack:(RTCAudioTrack*)audio
                   useLocalCapture:(BOOL)useLocalCapture;

- (void) close;

@end
