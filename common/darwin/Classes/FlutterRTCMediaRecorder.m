#import <WebRTC/WebRTC.h>
#import "FlutterRTCMediaRecorder.h"
#import "FlutterRTCAudioSink.h"
#import "FlutterRTCFrameCapturer.h"

@import AVFoundation;

static const int kViewerRecordingFrameRate = 18;
static const int kMotionRecordingFrameRate = 18;
static const CMTimeScale kMotionRecordingTimeScale = 90000;

@implementation FlutterRTCMediaRecorder {
    int framesCount;
    bool isInitialized;
    bool isStopping;
    int _audioFrameCount;
    int _audioAppendCount;
    int _audioDropCount;
    CGSize _renderSize;
    FlutterRTCAudioSink* _audioSink;
    AVAssetWriterInput* _audioWriter;
    dispatch_queue_t _audioAppendQueue;
    NSMutableArray<NSValue*>* _pendingAudioBuffers;
    int64_t _startTime;
    CMTime _motionRecordingStartTime;
    CMTime _nextMotionVideoHostTime;
    CMTime _lastMotionVideoPresentationTime;
}
- (void)drainPendingAudioBuffers {
    while (!isStopping &&
           self.assetWriter.status == AVAssetWriterStatusWriting &&
           _pendingAudioBuffers.count > 0 &&
           _audioWriter != nil &&
           _audioWriter.readyForMoreMediaData) {
        NSValue *value = _pendingAudioBuffers.firstObject;
        CMSampleBufferRef buffer = (CMSampleBufferRef)value.pointerValue;
        [_pendingAudioBuffers removeObjectAtIndex:0];
        if (buffer != NULL) {
            if ([_audioWriter appendSampleBuffer:buffer]) {
                _audioAppendCount++;
                if (_audioAppendCount <= 3 || _audioAppendCount % 500 == 0) {
                    NSLog(@"[SUR-REC][ios] audio appended #%d pending=%lu",
                          _audioAppendCount,
                          (unsigned long)_pendingAudioBuffers.count);
                }
            } else {
                _audioDropCount++;
                NSLog(@"[SUR-REC][ios] audio not appended #%d error=%@",
                      _audioDropCount,
                      self.assetWriter.error);
            }
            CFRelease(buffer);
        }
    }
}

- (void)releasePendingAudioBuffers {
    for (NSValue *value in _pendingAudioBuffers) {
        CMSampleBufferRef buffer = (CMSampleBufferRef)value.pointerValue;
        if (buffer != NULL) {
            CFRelease(buffer);
        }
    }
    [_pendingAudioBuffers removeAllObjects];
}

- (instancetype)initWithVideoTrack:(RTCVideoTrack *)video audioTrack:(RTCAudioTrack *)audio outputFile:(NSURL *)out {
    self = [super init];
    isInitialized = false;
    isStopping = false;
    _audioFrameCount = 0;
    _audioAppendCount = 0;
    _audioDropCount = 0;
    _audioAppendQueue = dispatch_queue_create("com.scanguardian.motion-recorder.audio", DISPATCH_QUEUE_SERIAL);
    _pendingAudioBuffers = [NSMutableArray array];
    self.videoTrack = video;
    self.output = out;
    [video addRenderer:self];
    framesCount = 0;
    if (audio != nil) {
        // Device motion 录的是本机麦克风，必须接入 WebRTC 本地采集处理链。
        // Viewer 手动录像录远端声音，继续使用远端 RTCAudioTrack renderer。
        BOOL useLocalAudioCapture = [out.path containsString:@".motion_recording.mp4"];
        _audioSink = [[FlutterRTCAudioSink alloc] initWithAudioTrack:audio
                                                   useLocalCapture:useLocalAudioCapture];
        NSLog(@"[SUR-REC][ios] recorder audio source=%@",
              useLocalAudioCapture ? @"local-capture" : @"remote-track");
    }
    else
        NSLog(@"Audio track is nil");
    _startTime = -1;
    _motionRecordingStartTime = kCMTimeInvalid;
    _nextMotionVideoHostTime = kCMTimeInvalid;
    _lastMotionVideoPresentationTime = kCMTimeInvalid;
    return self;
}

- (void)initialize:(CGSize)size rotation:(RTCVideoRotation)rotation {
    _renderSize = size;
    BOOL isMotionRecording = [self.output.path containsString:@".motion_recording.mp4"];
    NSNumber *averageVideoBitRate = isMotionRecording
        ? @(300000)
        : @(6000000);
    NSMutableDictionary *compressionProperties = [@{
        AVVideoAverageBitRateKey: averageVideoBitRate,
    } mutableCopy];
    if (isMotionRecording) {
        compressionProperties[AVVideoMaxKeyFrameIntervalKey] = @48;
        compressionProperties[AVVideoProfileLevelKey] = AVVideoProfileLevelH264BaselineAutoLevel;
        NSLog(@"[SUR-REC][ios] motion video bitrate=%@ size=%.0fx%.0f",
              averageVideoBitRate,
              size.width,
              size.height);
    }
    NSDictionary *videoSettings = @{
        AVVideoCompressionPropertiesKey: compressionProperties,
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoHeightKey: @(size.height),
        AVVideoWidthKey: @(size.width),
    };
    self.writerInput = [[AVAssetWriterInput alloc]
            initWithMediaType:AVMediaTypeVideo
               outputSettings:videoSettings];
    self.writerInput.expectsMediaDataInRealTime = true;
    if (isMotionRecording) {
        switch (rotation) {
            case RTCVideoRotation_90:
                self.writerInput.transform = CGAffineTransformMakeRotation(M_PI_2);
                break;
            case RTCVideoRotation_180:
                self.writerInput.transform = CGAffineTransformMakeRotation(M_PI);
                break;
            case RTCVideoRotation_270:
                self.writerInput.transform = CGAffineTransformMakeRotation(-M_PI_2);
                break;
            case RTCVideoRotation_0:
            default:
                self.writerInput.transform = CGAffineTransformIdentity;
                break;
        }
        NSLog(@"[SUR-REC][ios] motion video rotation=%ld transform=[%.0f %.0f %.0f %.0f]",
              (long)rotation,
              self.writerInput.transform.a,
              self.writerInput.transform.b,
              self.writerInput.transform.c,
              self.writerInput.transform.d);
    }
    // Viewer 录像沿用原来的固定帧计数时间轴。Motion 录像使用高精度时间轴，
    // 否则把本地约 30/36 FPS 的回调量化到 18 Hz 会把视频拉长成慢动作。
    self.writerInput.mediaTimeScale = isMotionRecording
        ? kMotionRecordingTimeScale
        : kViewerRecordingFrameRate;

    if (_audioSink != nil) {
        const AudioStreamBasicDescription *sourceAudioDescription = NULL;
        if (_audioSink.format != nil) {
            sourceAudioDescription = CMAudioFormatDescriptionGetStreamBasicDescription(_audioSink.format);
        }
        UInt32 channelCount = 1;
        Float64 sampleRate = 48000.0;
        if (sourceAudioDescription != NULL) {
            if (sourceAudioDescription->mChannelsPerFrame > 0) {
                channelCount = MIN(sourceAudioDescription->mChannelsPerFrame, 2);
            }
            if (sourceAudioDescription->mSampleRate > 0) {
                sampleRate = sourceAudioDescription->mSampleRate;
            }
        }
        AudioChannelLayout acl;
        bzero(&acl, sizeof(acl));
        acl.mChannelLayoutTag = channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo;
        NSDictionary* audioSettings = @{
            AVFormatIDKey: [NSNumber numberWithInt: kAudioFormatMPEG4AAC],
            AVNumberOfChannelsKey: @(channelCount),
            AVSampleRateKey: @(sampleRate),
            AVChannelLayoutKey: [NSData dataWithBytes:&acl length:sizeof(AudioChannelLayout)],
            AVEncoderBitRateKey: @(channelCount == 1 ? 64000 : 128000),
        };
        NSLog(@"[SUR-REC][ios] audio writer sampleRate=%.0f channels=%u sourceFormatReady=%d",
              sampleRate,
              (unsigned int)channelCount,
              _audioSink.format != nil);
        _audioWriter = [[AVAssetWriterInput alloc]
                        initWithMediaType:AVMediaTypeAudio
                        outputSettings:audioSettings
                        sourceFormatHint:_audioSink.format];
        _audioWriter.expectsMediaDataInRealTime = true;
    }
    
    NSError *error;
    self.assetWriter = [[AVAssetWriter alloc]
            initWithURL:self.output
               fileType:AVFileTypeMPEG4
                  error:&error];
    if (error != nil)
        NSLog(@"%@",[error localizedDescription]);
    self.assetWriter.shouldOptimizeForNetworkUse = true;
    [self.assetWriter addInput:self.writerInput];
    if (_audioWriter != nil) {
        [self.assetWriter addInput:_audioWriter];
    }

    BOOL didStartWriting = [self.assetWriter startWriting];
    if (!didStartWriting) {
        NSLog(@"[SUR-REC][ios] asset writer start failed error=%@",
              self.assetWriter.error);
        isInitialized = true;
        return;
    }
    [self.assetWriter startSessionAtSourceTime:kCMTimeZero];

    // 必须在 startSession 之后才开放音频回调，否则音频线程可能先于当前
    // 线程 append，AVAssetWriter 会因尚未开始 session 直接抛出异常。
    if (_audioWriter != nil) {
        _audioSink.bufferCallback = ^(CMSampleBufferRef buffer){
            if (self->isStopping ||
                self->_audioWriter == nil ||
                self.assetWriter.status != AVAssetWriterStatusWriting) {
                return;
            }
            CFRetain(buffer);
            dispatch_async(self->_audioAppendQueue, ^{
                if (self->isStopping ||
                    self->_audioWriter == nil ||
                    self.assetWriter.status != AVAssetWriterStatusWriting) {
                    CFRelease(buffer);
                    return;
                }
                self->_audioFrameCount++;
                if (self->_audioFrameCount <= 3) {
                    CMTime pts = CMSampleBufferGetPresentationTimeStamp(buffer);
                    NSLog(@"[SUR-REC][ios] audio sample #%d pts=%.3f ready=%d status=%ld",
                          self->_audioFrameCount,
                          CMTimeGetSeconds(pts),
                          self->_audioWriter.readyForMoreMediaData,
                          (long)self.assetWriter.status);
                }
                if (self->_pendingAudioBuffers.count >= 500) {
                    NSValue *oldestValue = self->_pendingAudioBuffers.firstObject;
                    CMSampleBufferRef oldestBuffer = (CMSampleBufferRef)oldestValue.pointerValue;
                    [self->_pendingAudioBuffers removeObjectAtIndex:0];
                    if (oldestBuffer != NULL) {
                        CFRelease(oldestBuffer);
                    }
                    self->_audioDropCount++;
                    if (self->_audioDropCount <= 3 || self->_audioDropCount % 100 == 0) {
                        NSLog(@"[SUR-REC][ios] audio queue overflow dropped=%d",
                              self->_audioDropCount);
                    }
                }
                [self->_pendingAudioBuffers addObject:[NSValue valueWithPointer:buffer]];
                [self drainPendingAudioBuffers];
            });
        };
    }
    
    isInitialized = true;
}

- (void)setSize:(CGSize)size {
}

- (void)renderFrame:(nullable RTCVideoFrame *)frame {
    if (frame == nil) {
        return;
    }
    if (!isInitialized) {
        [self initialize:CGSizeMake((CGFloat) frame.width, (CGFloat) frame.height) rotation:frame.rotation];
    }
    if (!self.writerInput.readyForMoreMediaData) {
        NSLog(@"Drop frame, not ready");
        return;
    }
    BOOL isMotionRecording = [self.output.path containsString:@".motion_recording.mp4"];
    CMTime motionNow = kCMTimeInvalid;
    CMTime motionPresentationTime = kCMTimeInvalid;
    if (isMotionRecording) {
        motionNow = CMClockGetTime(CMClockGetHostTimeClock());
        if (!CMTIME_IS_VALID(_motionRecordingStartTime)) {
            _motionRecordingStartTime = motionNow;
            _nextMotionVideoHostTime = motionNow;
        }

        // 本地摄像头可能忽略 getUserMedia 的 maxFrameRate，主动限制 Motion
        // 写入为 18 FPS。5 ms 容差避免 36 FPS 输入因调度抖动误降为 12 FPS。
        CMTime schedulingTolerance = CMTimeMake(1, 200);
        if (CMTIME_IS_VALID(_nextMotionVideoHostTime) &&
            CMTimeCompare(CMTimeAdd(motionNow, schedulingTolerance),
                          _nextMotionVideoHostTime) < 0) {
            return;
        }

        CMTime elapsed = CMTimeSubtract(motionNow, _motionRecordingStartTime);
        motionPresentationTime = CMTimeConvertScale(
            elapsed,
            kMotionRecordingTimeScale,
            kCMTimeRoundingMethod_RoundHalfAwayFromZero);
        if (CMTIME_IS_VALID(_lastMotionVideoPresentationTime) &&
            CMTimeCompare(motionPresentationTime,
                          _lastMotionVideoPresentationTime) <= 0) {
            motionPresentationTime = CMTimeAdd(
                _lastMotionVideoPresentationTime,
                CMTimeMake(1, kMotionRecordingTimeScale));
        }
    }
    id <RTCVideoFrameBuffer> buffer = frame.buffer;
    CVPixelBufferRef pixelBufferRef;
    BOOL shouldRelease = false;
    if ([buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
        pixelBufferRef = ((RTCCVPixelBuffer *) buffer).pixelBuffer;
    } else {
        pixelBufferRef = [FlutterRTCFrameCapturer convertToCVPixelBuffer:frame];
        shouldRelease = true;
    }
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBufferRef, &formatDescription);
    
    if (status != noErr || formatDescription == NULL) {
        NSLog(@"Failed to create format description: %d", (int)status);
        if (shouldRelease) {
            CVPixelBufferRelease(pixelBufferRef);
        }
        return;
    }

    CMSampleTimingInfo timingInfo;
    
    timingInfo.decodeTimeStamp = kCMTimeInvalid;
    if (isMotionRecording) {
        timingInfo.duration = CMTimeMake(1, kMotionRecordingFrameRate);
        timingInfo.presentationTimeStamp = motionPresentationTime;
    } else {
        CMTimeScale timeScale = self.writerInput.mediaTimeScale > 0
            ? self.writerInput.mediaTimeScale
            : kViewerRecordingFrameRate;
        timingInfo.duration = CMTimeMake(1, timeScale);
        timingInfo.presentationTimeStamp = CMTimeMake(framesCount, timeScale);
    }

    CMSampleBufferRef outBuffer = NULL;

    status = CMSampleBufferCreateReadyWithImageBuffer(
        kCFAllocatorDefault,
        pixelBufferRef,
        formatDescription,
        &timingInfo,
        &outBuffer
    );

    if (status == noErr && outBuffer != NULL) {
        if ([self.writerInput appendSampleBuffer:outBuffer]) {
            framesCount++;
            if (isMotionRecording) {
                _lastMotionVideoPresentationTime = timingInfo.presentationTimeStamp;
                CMTime frameInterval = CMTimeMake(1, kMotionRecordingFrameRate);
                CMTime nextScheduledTime = CMTimeAdd(
                    _nextMotionVideoHostTime,
                    frameInterval);
                // App/编码线程若长时间挂起，从当前时间重新排期，避免恢复后突发补帧。
                if (CMTimeCompare(motionNow,
                                  CMTimeAdd(nextScheduledTime, frameInterval)) > 0) {
                    nextScheduledTime = CMTimeAdd(motionNow, frameInterval);
                }
                _nextMotionVideoHostTime = nextScheduledTime;
            }
        } else {
            NSLog(@"Frame not appended %@", self.assetWriter.error);
        }
    } else {
        NSLog(@"Failed to create sample buffer: %d", (int)status);
    }
    
    // Release Core Foundation objects to prevent memory leaks
    if (outBuffer != NULL) {
        CFRelease(outBuffer);
    }
    if (formatDescription != NULL) {
        CFRelease(formatDescription);
    }
    if (shouldRelease) {
        CVPixelBufferRelease(pixelBufferRef);
    }
}

- (void)stop:(FlutterResult _Nonnull) result {
    isStopping = true;
    if (_audioSink != nil) {
        _audioSink.bufferCallback = nil;
        [_audioSink close];
    }
    if (_audioAppendQueue != nil) {
        dispatch_sync(_audioAppendQueue, ^{
            [self releasePendingAudioBuffers];
        });
    }
    NSLog(@"[SUR-REC][ios] stop audioFrames=%d appended=%d dropped=%d",
          _audioFrameCount,
          _audioAppendCount,
          _audioDropCount);
    if (CMTIME_IS_VALID(_lastMotionVideoPresentationTime)) {
        NSLog(@"[SUR-REC][ios] stop motionVideoFrames=%d duration=%.3f",
              framesCount,
              CMTimeGetSeconds(_lastMotionVideoPresentationTime));
    }
    [self.videoTrack removeRenderer:self];
    [self.writerInput markAsFinished];
    [_audioWriter markAsFinished];
    dispatch_async(dispatch_get_main_queue(), ^{
       [self.assetWriter finishWritingWithCompletionHandler:^{
           NSError* error = self.assetWriter.error;
           if (error == nil) {
               result(nil);
           } else {
               result([FlutterError errorWithCode:@"Failed to save recording"
                                          message:[error localizedDescription]
                                          details:nil]);
           }
       }];
    });
}

@end
