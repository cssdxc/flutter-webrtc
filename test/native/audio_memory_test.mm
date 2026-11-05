// Runs the real Darwin PCM sink and adapter without a microphone or Flutter engine.
#import <AVFoundation/AVFoundation.h>
#import <mach/mach.h>
#import "AudioManager.h"
#import "FlutterRTCAudioSink.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>

// Keep the sink detached from hardware for this standalone regression test.
@implementation AudioManager
+ (instancetype)sharedInstance {
  static AudioManager *manager;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ manager = [AudioManager new]; });
  return manager;
}
- (void)addLocalAudioRenderer:(id<RTCAudioRenderer>)renderer {}
- (void)removeLocalAudioRenderer:(id<RTCAudioRenderer>)renderer {}
@end

@interface TestAudioBuffer : NSObject
@property(nonatomic) size_t testChannels;
- (size_t)channels;
- (size_t)frames;
- (size_t)framesPerBand;
- (size_t)bands;
- (float *)rawBufferForChannel:(size_t)channel;
@end
@implementation TestAudioBuffer {
  float _samples[2][480];
}
- (instancetype)init {
  if ((self = [super init])) {
    _testChannels = 1;
    for (size_t i = 0; i < 480; i++) {
      _samples[0][i] = 8192.0f;
      _samples[1][i] = -16384.0f;
    }
  }
  return self;
}
- (size_t)channels { return _testChannels; }
- (size_t)frames { return 480; }
- (size_t)framesPerBand { return 160; }
- (size_t)bands { return 3; }
- (float *)rawBufferForChannel:(size_t)channel { return _samples[channel]; }
@end

@interface TestMutatingRenderer : NSObject <RTCAudioRenderer>
@end
@implementation TestMutatingRenderer
- (void)renderPCMBuffer:(AVAudioPCMBuffer *)buffer {
  buffer.floatChannelData[0][0] = -.75f;
}
@end

@interface TestObservingRenderer : NSObject <RTCAudioRenderer>
@property(nonatomic, copy) void (^inspect)(AVAudioPCMBuffer *);
@end
@implementation TestObservingRenderer
- (void)renderPCMBuffer:(AVAudioPCMBuffer *)buffer { self.inspect(buffer); }
@end

static void require(bool condition, const char *message) {
  if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

// This owner compiles the actual plugin callback extracted by the test runner.
// Flutter engine/device setup is intentionally outside this native unit test.
@interface FlutterWebRTCPlugin : NSObject {
@public
  void (^_audioPcmEventSink)(id);
  NSMutableDictionary<NSString *, FlutterRTCAudioSink *> *_pcmAudioSinks;
}
- (FlutterRTCAudioSink *)startTestCapture:(NSString *)trackId;
@end
@implementation FlutterWebRTCPlugin
- (instancetype)init {
  if ((self = [super init])) _pcmAudioSinks = [NSMutableDictionary new];
  return self;
}
- (FlutterRTCAudioSink *)startTestCapture:(NSString *)trackId {
  FlutterRTCAudioSink *sink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:nil];
#include "pcm_event_callback.inc"
  _pcmAudioSinks[trackId] = sink;
  return sink;
}
@end

static void flushMainQueue() {
  __block bool finished = false;
  dispatch_async(dispatch_get_main_queue(), ^{ finished = true; });
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
  while (!finished && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                        beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  }
  require(finished, "main queue drains without blocking the audio producer");
}

static void enqueuePCMBatches(FlutterRTCAudioSink *sink, int batches) {
  dispatch_sync(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    @autoreleasepool {
      float samples[4800];
      for (int i = 0; i < 4800; i++) samples[i] = .25f;
      for (int i = 0; i < batches; i++) sink.pcmCallback(samples, 4800, 48000, 1);
      // Producer memory must be copied before returning to the audio thread.
      for (int i = 0; i < 4800; i++) samples[i] = -.5f;
    }
  });
}

static void checkPCMEventQueueLifecycle() {
  FlutterWebRTCPlugin *owner = [FlutterWebRTCPlugin new];
  __block int events = 0;
  owner->_audioPcmEventSink = ^(id value) {
    require([NSThread isMainThread], "PCM events are delivered on main thread");
    NSDictionary *event = value;
    NSData *data = event[@"data"];
    require([event[@"trackId"] isEqual:@"test-track"] &&
            [event[@"frames"] intValue] == 4800 &&
            [event[@"sampleRate"] intValue] == 48000 &&
            [event[@"channels"] intValue] == 1 &&
            [event[@"bitsPerSample"] intValue] == 32 && data.length == 19200,
            "PCM platform event preserves field names and values");
    const float *samples = (const float *)data.bytes;
    require(samples[0] == .25f && samples[4799] == .25f,
            "queued PCM owns its samples after audio callback returns");
    events++;
  };
  FlutterRTCAudioSink *sink;
  __weak FlutterRTCAudioSink *stoppedSink;
  @autoreleasepool {
    sink = [owner startTestCapture:@"test-track"];
    enqueuePCMBatches(sink, 5000);
    require(events == 0, "audio producer does not wait for platform delivery");
    flushMainQueue();
    require(events == 2, "busy platform queue holds at most two detection batches");
    enqueuePCMBatches(sink, 1);
    flushMainQueue();
    require(events == 3, "queue capacity recovers after delivery");

    enqueuePCMBatches(sink, 2);
    [sink close];
    [owner->_pcmAudioSinks removeAllObjects];
    stoppedSink = sink;
    sink = nil;
  }
  require(stoppedSink == nil, "pending events do not retain stopped sink");
  flushMainQueue();
  require(events == 3, "released sink cannot deliver stale events when registry is empty");

  sink = [owner startTestCapture:@"test-track"];
  enqueuePCMBatches(sink, 2);
  FlutterRTCAudioSink *replacement = [owner startTestCapture:@"test-track"];
  flushMainQueue();
  require(events == 3, "replaced capture drops old generation events");
  enqueuePCMBatches(replacement, 1);
  flushMainQueue();
  require(events == 4, "replacement capture delivers its own events");
  enqueuePCMBatches(replacement, 2);
  void (^listener)(id) = owner->_audioPcmEventSink;
  owner->_audioPcmEventSink = nil;
  flushMainQueue();
  require(events == 4, "cancelled event listener receives no queued PCM");
  owner->_audioPcmEventSink = listener;
  enqueuePCMBatches(replacement, 2);
  flushMainQueue();
  require(events == 6, "skipped events release queue capacity for later delivery");
  [sink close];
  [replacement close];
  [owner->_pcmAudioSinks removeAllObjects];
}

static uint64_t footprint() {
  task_vm_info_data_t info = {};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  require(task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS,
          "read memory footprint");
  return info.phys_footprint;
}
static AVAudioPCMBuffer *pcm(AVAudioCommonFormat commonFormat, int channels, bool interleaved,
                            double sampleRate = 48000, AVAudioFrameCount frames = 480) {
  AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:commonFormat
      sampleRate:sampleRate channels:channels interleaved:interleaved];
  AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frames];
  buffer.frameLength = frames;
  for (int ch = 0; ch < channels; ch++) {
    for (AVAudioFrameCount frame = 0; frame < frames; frame++) {
      int plane = interleaved ? 0 : ch;
      int offset = interleaved ? frame * channels + ch : frame;
      float value = ch == 0 ? 0.25f : -0.5f;
      if (commonFormat == AVAudioPCMFormatFloat32) buffer.floatChannelData[plane][offset] = value;
      else buffer.int16ChannelData[plane][offset] = (int16_t)(value * 32768.0f);
    }
  }
  return buffer;
}
static void checkRecording(AVAudioCommonFormat commonFormat, int channels, bool interleaved) {
  FlutterRTCAudioSink *sink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:nil];
  AVAudioPCMBuffer *buffer = pcm(commonFormat, channels, interleaved);
  const int prewriterFrames = 6;
  for (int i = 0; i < prewriterFrames; i++) [sink renderPCMBuffer:buffer];
  const AudioStreamBasicDescription *hint = CMAudioFormatDescriptionGetStreamBasicDescription(sink.format);
  require(hint != NULL && hint->mChannelsPerFrame == channels && hint->mSampleRate == 48000,
          "recorder format hint available before writer starts");
  __block int callbacks = 0;
  sink.bufferCallback = ^(CMSampleBufferRef sample) {
    require(CMSampleBufferDataIsReady(sample), "recording data ready");
    require(CMSampleBufferGetNumSamples(sample) == 480, "recording frame count");
    require(fabs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - (prewriterFrames + callbacks) * .01) < .00001,
            "recording timestamps preserve elapsed capture time before writer starts");
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    float samples[960];
    require(CMBlockBufferGetDataLength(block) == 480 * channels * sizeof(float), "recording byte count");
    require(CMBlockBufferCopyDataBytes(block, 0, 480 * channels * sizeof(float), samples) == noErr,
            "recording data readable");
    require(samples[0] == .25f && (channels == 1 || samples[1] == -.5f), "recording PCM conversion");
    callbacks++;
  };
  for (int i = 0; i < 20; i++) [sink renderPCMBuffer:buffer];
  require(callbacks == 20 && sink.format != NULL, "recording format and callbacks preserved");
  [sink close];
  [sink renderPCMBuffer:buffer];
  require(callbacks == 20, "closed sink stops callbacks");
}
static void checkMemory(bool throughAdapter, bool recording) {
  FlutterRTCAudioSink *sink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:nil];
  AudioProcessingAdapter *adapter = [AudioProcessingAdapter new];
  [adapter audioProcessingInitializeWithSampleRate:48000 channels:1];
  [adapter addAudioRenderer:sink];
  TestAudioBuffer *source = [TestAudioBuffer new];
  AVAudioPCMBuffer *buffer = pcm(AVAudioPCMFormatFloat32, 1, false);
  __block size_t batches = 0;
  __block size_t recordedFrames = 0;
  if (recording) {
    sink.bufferCallback = ^(CMSampleBufferRef sample) {
      require(CMSampleBufferDataIsReady(sample), "stress recording data ready");
      recordedFrames++;
    };
  }
  sink.pcmCallback = ^(const float *samples, size_t count, int rate, size_t channels) {
    require(count == 4800 && rate == 48000 && channels == 1, "100 ms PCM batches");
    require(samples[0] == .25f && samples[count - 1] == .25f, "normalized PCM samples");
    batches++;
  };
  void (^process)(void) = ^{
    if (throughAdapter) [adapter audioProcessingProcess:(RTCAudioBuffer *)source];
    else [sink renderPCMBuffer:buffer];
  };
  for (int i = 0; i < 1000; i++) { @autoreleasepool { process(); } }
  uint64_t before = footprint();
  // Deliberately use one outer pool, just like a long-lived WebRTC thread.
  // Per-callback pools must be owned by the production audio boundary.
  for (int i = 0; i < 30000; i++) process();
  int64_t growth = (int64_t)footprint() - (int64_t)before;
  printf("%s (%s): 30000 frames, growth %.2f MiB, %zu batches\n",
         throughAdapter ? "local adapter + sink" : "remote sink",
         recording ? "PCM + recording" : "PCM only", growth / 1048576.0, batches);
  require(growth < 8 * 1024 * 1024, "audio memory remains bounded");
  require(batches == 3100, "all audio batches delivered");
  require(recording ? (sink.format != NULL && recordedFrames == 31000) : sink.format == NULL,
          "recording buffers created only for recording consumers");
  [adapter removeAudioRenderer:sink];
  [sink close];
}

static void checkSharedCaptureAndRetainedRecording() {
  AudioProcessingAdapter *adapter = [AudioProcessingAdapter new];
  [adapter audioProcessingInitializeWithSampleRate:48000 channels:1];
  TestAudioBuffer *source = [TestAudioBuffer new];
  FlutterRTCAudioSink *detection = [[FlutterRTCAudioSink alloc] initWithAudioTrack:nil];
  FlutterRTCAudioSink *recording = [[FlutterRTCAudioSink alloc] initWithAudioTrack:nil];
  __block size_t batches = 0;
  __block int recordedFrames = 0;
  __block CMSampleBufferRef retainedSample = NULL;
  detection.pcmCallback = ^(const float *samples, size_t count, int rate, size_t channels) {
    require(count == 4800 && rate == 48000 && channels == 1, "shared capture batch format");
    require(samples[0] == .25f && samples[count - 1] == .25f, "shared capture detection samples");
    batches++;
  };
  recording.bufferCallback = ^(CMSampleBufferRef sample) {
    require(fabs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - recordedFrames * .01) < .00001,
            "recording timeline survives renderer detach and reattach");
    if (retainedSample == NULL) retainedSample = (CMSampleBufferRef)CFRetain(sample);
    recordedFrames++;
  };
  [adapter addAudioRenderer:detection];
  [adapter addAudioRenderer:recording];
  for (int i = 0; i < 20; i++) [adapter audioProcessingProcess:(RTCAudioBuffer *)source];
  require(batches == 2 && recordedFrames == 20, "detection and recorder share capture without missing frames");
  [adapter removeAudioRenderer:recording];
  for (int i = 0; i < 10; i++) [adapter audioProcessingProcess:(RTCAudioBuffer *)source];
  require(batches == 3 && recordedFrames == 20, "removing recorder preserves detection capture");
  [adapter addAudioRenderer:recording];
  for (int i = 0; i < 10; i++) [adapter audioProcessingProcess:(RTCAudioBuffer *)source];
  require(batches == 4 && recordedFrames == 30, "recorder reattaches without duplicate callbacks");
  require([source rawBufferForChannel:0][0] == 8192.0f &&
          [source rawBufferForChannel:0][479] == 8192.0f,
          "PCM consumers do not modify WebRTC call audio samples");
  [adapter removeAudioRenderer:detection];
  [adapter removeAudioRenderer:recording];
  [detection close];
  [recording close];
  [adapter audioProcessingProcess:(RTCAudioBuffer *)source];
  require(batches == 4 && recordedFrames == 30, "detached consumers receive no further frames");
  float samples[480];
  require(retainedSample != NULL && CMSampleBufferDataIsReady(retainedSample) &&
          CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(retainedSample), 0, sizeof(samples), samples) == noErr,
          "async recorder retains readable samples after audio autorelease pools drain");
  require(samples[0] == .25f && samples[479] == .25f, "retained recording data remains unchanged");
  CFRelease(retainedSample);
}

static void checkRendererIsolationAndFormatChanges() {
  AudioProcessingAdapter *adapter = [AudioProcessingAdapter new];
  TestAudioBuffer *source = [TestAudioBuffer new];
  TestMutatingRenderer *mutator = [TestMutatingRenderer new];
  TestObservingRenderer *observer = [TestObservingRenderer new];
  __block double expectedRate = 48000;
  __block size_t expectedChannels = 1;
  __block int callbacks = 0;
  observer.inspect = ^(AVAudioPCMBuffer *buffer) {
    require(buffer.floatChannelData[0][0] == .25f,
            "one renderer cannot mutate another renderer's audio copy");
    require(buffer.format.sampleRate == expectedRate, "cached format follows capture reinitialization");
    require(buffer.format.channelCount == expectedChannels, "cached format follows channel changes");
    if (expectedChannels == 2) require(buffer.floatChannelData[1][0] == -.5f, "stereo channels remain separate");
    callbacks++;
  };
  [adapter addAudioRenderer:mutator];
  [adapter addAudioRenderer:observer];
  const int rates[] = {48000, 16000, 48000, 0};
  const size_t channels[] = {1, 2, 1, 1};
  for (int i = 0; i < 4; i++) {
    expectedRate = rates[i] > 0 ? rates[i] : 48000;
    expectedChannels = channels[i];
    source.testChannels = channels[i];
    [adapter audioProcessingInitializeWithSampleRate:rates[i] channels:channels[i]];
    [adapter audioProcessingProcess:(RTCAudioBuffer *)source];
  }
  require(callbacks == 4 && [source rawBufferForChannel:0][0] == 8192.0f,
          "renderer mutation leaves call audio unchanged");
  [adapter removeAudioRenderer:mutator];
  [adapter removeAudioRenderer:observer];
}

static void checkPCMBatchFormatChanges() {
  FlutterRTCAudioSink *sink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:nil];
  __block int batches = 0;
  sink.pcmCallback = ^(const float *samples, size_t count, int rate, size_t channels) {
    require(samples[0] == .25f, "format change preserves PCM levels");
    if (batches == 0) {
      require(rate == 16000 && channels == 1 && count == 1600,
              "new sample rate discards incomplete old batch");
    } else {
      require(rate == 48000 && channels == 2 && count == 9600 && samples[1] == -.5f,
              "new channel layout produces interleaved 100 ms batches");
    }
    batches++;
  };
  AVAudioPCMBuffer *mono48k = pcm(AVAudioPCMFormatFloat32, 1, false);
  for (int i = 0; i < 5; i++) [sink renderPCMBuffer:mono48k];
  require(batches == 0, "partial PCM batch waits for more input");
  AVAudioPCMBuffer *mono16k = pcm(AVAudioPCMFormatInt16, 1, false, 16000, 160);
  for (int i = 0; i < 10; i++) [sink renderPCMBuffer:mono16k];
  require(batches == 1, "sample rate change produces exactly one new batch");
  AVAudioPCMBuffer *stereo48k = pcm(AVAudioPCMFormatFloat32, 2, true);
  for (int i = 0; i < 10; i++) [sink renderPCMBuffer:stereo48k];
  require(batches == 2 && sink.format == NULL, "PCM-only format changes do not allocate recorder format");
  [sink close];
  [sink renderPCMBuffer:stereo48k];
  require(batches == 2, "closed PCM consumer stops all batches");
}

int main() {
  @autoreleasepool {
    checkPCMEventQueueLifecycle();
    checkRendererIsolationAndFormatChanges();
    checkPCMBatchFormatChanges();
    checkSharedCaptureAndRetainedRecording();
    checkMemory(false, false);
    checkMemory(true, false);
    checkMemory(false, true);
    checkMemory(true, true);
    for (AVAudioCommonFormat format : {AVAudioPCMFormatFloat32, AVAudioPCMFormatInt16}) {
      checkRecording(format, 1, false);
      checkRecording(format, 2, false);
      checkRecording(format, 2, true);
    }
    puts("PASS: Darwin audio memory, renderer isolation, format changes, PCM queue lifecycle, recording timestamps, and close");
  }
}
