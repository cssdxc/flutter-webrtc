#import "AudioProcessingAdapter.h"
#import <WebRTC/RTCAudioRenderer.h>
#import <math.h>
#import <os/lock.h>

@implementation AudioProcessingAdapter {
  NSMutableArray<id<RTCAudioRenderer>>* _renderers;
  NSMutableArray<id<ExternalAudioProcessingDelegate>>* _processors;
  os_unfair_lock _lock;
  size_t _sampleRateHz;
  size_t _channelCount;
  BOOL _loggedCaptureFormat;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _renderers = [[NSMutableArray<id<RTCAudioRenderer>> alloc] init];
    _processors = [[NSMutableArray<id<ExternalAudioProcessingDelegate>> alloc] init];
    _sampleRateHz = 0;
    _channelCount = 0;
    _loggedCaptureFormat = NO;
  }
  return self;
}

- (void)addProcessing:(id<ExternalAudioProcessingDelegate> _Nonnull)processor {
  os_unfair_lock_lock(&_lock);
  [_processors addObject:processor];
  os_unfair_lock_unlock(&_lock);
}

- (void)removeProcessing:(id<ExternalAudioProcessingDelegate> _Nonnull)processor {
  os_unfair_lock_lock(&_lock);
  _processors = [[_processors
      filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject,
                                                                        NSDictionary* bindings) {
        return evaluatedObject != processor;
      }]] mutableCopy];
  os_unfair_lock_unlock(&_lock);
}

- (void)addAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer {
  os_unfair_lock_lock(&_lock);
  [_renderers addObject:renderer];
  os_unfair_lock_unlock(&_lock);
}

- (void)removeAudioRenderer:(nonnull id<RTCAudioRenderer>)renderer {
  os_unfair_lock_lock(&_lock);
  _renderers = [[_renderers
      filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id evaluatedObject,
                                                                        NSDictionary* bindings) {
        return evaluatedObject != renderer;
      }]] mutableCopy];
  os_unfair_lock_unlock(&_lock);
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
  os_unfair_lock_lock(&_lock);
  _sampleRateHz = sampleRateHz;
  _channelCount = channels;
  _loggedCaptureFormat = NO;
  for (id<ExternalAudioProcessingDelegate> processor in _processors) {
    [processor audioProcessingInitializeWithSampleRate:sampleRateHz channels:channels];
  }
  os_unfair_lock_unlock(&_lock);
}

- (AVAudioPCMBuffer*)toPCMBuffer:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  double sampleRate = _sampleRateHz > 0
      ? (double)_sampleRateHz
      : (double)audioBuffer.frames * 100.0;
  AVAudioChannelCount channelCount = (AVAudioChannelCount)audioBuffer.channels;
  if (_channelCount > 0) {
    channelCount = (AVAudioChannelCount)MIN(_channelCount, audioBuffer.channels);
  }
  AVAudioFormat* format =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                       sampleRate:sampleRate
                                         channels:channelCount
                                      interleaved:NO];
  AVAudioPCMBuffer* pcmBuffer =
      [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                    frameCapacity:(AVAudioFrameCount)audioBuffer.frames];
  if (!pcmBuffer) {
    NSLog(@"Failed to create AVAudioPCMBuffer");
    return nil;
  }
  pcmBuffer.frameLength = (AVAudioFrameCount)audioBuffer.frames;
  float peakRawSample = 0.0f;
  for (AVAudioChannelCount i = 0; i < channelCount; i++) {
    float* sourceBuffer = [audioBuffer rawBufferForChannel:i];
    float* targetBuffer = pcmBuffer.floatChannelData[i];
    for (size_t frame = 0; frame < audioBuffer.frames; frame++) {
      // WebRTC AudioBuffer 的 float 样本沿用 S16 幅值，AVAudioPCMFormatFloat32
      // 则要求 -1...1；直接复制会全部削顶并产生持续炸音。
      float rawSample = sourceBuffer[frame];
      peakRawSample = MAX(peakRawSample, fabsf(rawSample));
      targetBuffer[frame] = fmaxf(-1.0f, fminf(1.0f, rawSample / 32768.0f));
    }
  }
  if (!_loggedCaptureFormat) {
    NSLog(@"[SUR-REC][ios] local capture format sampleRate=%.0f channels=%u frames=%lu framesPerBand=%lu bands=%lu peakRaw=%.1f",
          sampleRate,
          (unsigned int)channelCount,
          (unsigned long)audioBuffer.frames,
          (unsigned long)audioBuffer.framesPerBand,
          (unsigned long)audioBuffer.bands,
          peakRawSample);
    _loggedCaptureFormat = YES;
  }
  return pcmBuffer;
}

- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  os_unfair_lock_lock(&_lock);
  for (id<ExternalAudioProcessingDelegate> processor in _processors) {
    [processor audioProcessingProcess:audioBuffer];
  }

  for (id<RTCAudioRenderer> renderer in _renderers) {
    [renderer renderPCMBuffer:[self toPCMBuffer:audioBuffer]];
  }
  os_unfair_lock_unlock(&_lock);
}

- (void)audioProcessingRelease {
  os_unfair_lock_lock(&_lock);
  for (id<ExternalAudioProcessingDelegate> processor in _processors) {
    [processor audioProcessingRelease];
  }
  os_unfair_lock_unlock(&_lock);
}

@end
