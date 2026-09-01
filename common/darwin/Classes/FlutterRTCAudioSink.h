#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <WebRTC/WebRTC.h>

@interface FlutterRTCAudioSink : NSObject

@property (nonatomic, copy) void (^bufferCallback)(CMSampleBufferRef);
@property (nonatomic, copy) void (^pcmCallback)(const float *samples,
                                                 size_t sampleCount,
                                                 int sampleRate,
                                                 size_t channels);
@property (nonatomic) CMAudioFormatDescriptionRef format;

- (instancetype) initWithAudioTrack:(RTCAudioTrack* _Nullable)audio;

// Device motion 录像和端侧检测共享独立的本地麦克风 PCM 采集；Viewer
// 录像仍从远端音轨获取播放 PCM，两个入口不能混用同一个 renderer 接入方式。
- (instancetype) initWithAudioTrack:(RTCAudioTrack* _Nullable)audio
                   useLocalCapture:(BOOL)useLocalCapture;

- (void) close;

@end
