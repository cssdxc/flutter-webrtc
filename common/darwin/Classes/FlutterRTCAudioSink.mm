#import <AVFoundation/AVFoundation.h>
#import "FlutterRTCAudioSink.h"
#import "AudioManager.h"
#import <WebRTC/RTCAudioRenderer.h>

@interface FlutterRTCAudioSink ()
- (CMSampleTimingInfo)nextAudioTimingWithSampleRate:(int)sampleRate
                                    numberOfFrames:(size_t)numberOfFrames;
- (void)updateFormatIfNeeded:(CMAudioFormatDescriptionRef)format;
@end

@implementation FlutterRTCAudioSink {
    RTCAudioTrack *_audioTrack;
    int64_t _audioSamplePosition;
    BOOL _closed;
    BOOL _usesLocalCapture;
    BOOL _loggedFormat;
    int _dataBufferErrorCount;
}

- (instancetype) initWithAudioTrack:(RTCAudioTrack* )audio {
    return [self initWithAudioTrack:audio useLocalCapture:NO];
}

- (instancetype) initWithAudioTrack:(RTCAudioTrack* )audio
                   useLocalCapture:(BOOL)useLocalCapture {
    self = [super init];
    _audioSamplePosition = 0;
    _closed = NO;
    _usesLocalCapture = useLocalCapture;
    _loggedFormat = NO;
    _dataBufferErrorCount = 0;
    _audioTrack = audio;
    if (_usesLocalCapture) {
        [AudioManager.sharedInstance addLocalAudioRenderer:self];
        NSLog(@"[SUR-REC][ios] local capture renderer attached track=%@", _audioTrack);
    } else {
        [_audioTrack addRenderer:self];
        NSLog(@"[SUR-REC][ios] remote track renderer attached track=%@", _audioTrack);
    }
    return self;
}

- (void) close {
    if (_closed) {
        return;
    }
    _closed = YES;
    if (_audioTrack != nil) {
        if (_usesLocalCapture) {
            [AudioManager.sharedInstance removeLocalAudioRenderer:self];
            NSLog(@"[SUR-REC][ios] local capture renderer detached track=%@", _audioTrack);
        } else {
            [_audioTrack removeRenderer:self];
            NSLog(@"[SUR-REC][ios] remote track renderer detached track=%@", _audioTrack);
        }
        _audioTrack = nil;
    }
}

- (CMSampleTimingInfo)nextAudioTimingWithSampleRate:(int)sampleRate
                                    numberOfFrames:(size_t)numberOfFrames {
    CMSampleTimingInfo timing;
    timing.decodeTimeStamp = kCMTimeInvalid;
    timing.presentationTimeStamp = CMTimeMake(_audioSamplePosition, sampleRate);
    timing.duration = CMTimeMake((int64_t)numberOfFrames, sampleRate);
    _audioSamplePosition += (int64_t)numberOfFrames;
    return timing;
}

- (void)updateFormatIfNeeded:(CMAudioFormatDescriptionRef)format {
    if (self.format == nil && format != NULL) {
        self.format = (CMAudioFormatDescriptionRef)CFRetain(format);
    }
}

- (void)dealloc {
    [self close];
    if (self.format != nil) {
        CFRelease(self.format);
        self.format = nil;
    }
}

- (void)renderPCMBuffer:(AVAudioPCMBuffer *)pcmBuffer
{
    if (_closed || pcmBuffer == nil || pcmBuffer.frameLength == 0) {
        return;
    }

    const AudioStreamBasicDescription *sourceDescription = pcmBuffer.format.streamDescription;
    if (sourceDescription == NULL || sourceDescription->mSampleRate <= 0) {
        return;
    }

    UInt32 channelCount = sourceDescription->mChannelsPerFrame > 0
        ? sourceDescription->mChannelsPerFrame
        : 1;
    AVAudioFrameCount frameLength = pcmBuffer.frameLength;
    size_t sampleCount = (size_t)frameLength * channelCount;
    NSMutableData *interleavedData =
        [NSMutableData dataWithLength:sampleCount * sizeof(float)];
    float *target = (float *)interleavedData.mutableBytes;
    if (target == NULL) {
        return;
    }

    // AVAssetWriter 需要布局明确且内存连续的 PCM。WebRTC 通常给出非交错
    // Float32，不能直接把原 AudioBufferList 当成一段连续数据写入。
    if (pcmBuffer.floatChannelData != NULL) {
        if (pcmBuffer.format.isInterleaved) {
            memcpy(target,
                   pcmBuffer.floatChannelData[0],
                   sampleCount * sizeof(float));
        } else {
            for (AVAudioFrameCount frame = 0; frame < frameLength; frame++) {
                for (UInt32 channel = 0; channel < channelCount; channel++) {
                    target[(size_t)frame * channelCount + channel] =
                        pcmBuffer.floatChannelData[channel][frame];
                }
            }
        }
    } else if (pcmBuffer.int16ChannelData != NULL) {
        if (pcmBuffer.format.isInterleaved) {
            for (size_t sample = 0; sample < sampleCount; sample++) {
                target[sample] =
                    (float)pcmBuffer.int16ChannelData[0][sample] / 32768.0f;
            }
        } else {
            for (AVAudioFrameCount frame = 0; frame < frameLength; frame++) {
                for (UInt32 channel = 0; channel < channelCount; channel++) {
                    target[(size_t)frame * channelCount + channel] =
                        (float)pcmBuffer.int16ChannelData[channel][frame] /
                        32768.0f;
                }
            }
        }
    } else {
        if (!_loggedFormat) {
            NSLog(@"[SUR-REC][ios] unsupported audio pcm buffer format flags=%u bits=%u channels=%u",
                  (unsigned int)sourceDescription->mFormatFlags,
                  (unsigned int)sourceDescription->mBitsPerChannel,
                  (unsigned int)channelCount);
            _loggedFormat = YES;
        }
        return;
    }

    AudioStreamBasicDescription streamDescription;
    bzero(&streamDescription, sizeof(streamDescription));
    streamDescription.mSampleRate = sourceDescription->mSampleRate;
    streamDescription.mFormatID = kAudioFormatLinearPCM;
    streamDescription.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    streamDescription.mBytesPerPacket = sizeof(float) * channelCount;
    streamDescription.mFramesPerPacket = 1;
    streamDescription.mBytesPerFrame = sizeof(float) * channelCount;
    streamDescription.mChannelsPerFrame = channelCount;
    streamDescription.mBitsPerChannel = 8 * sizeof(float);

    if (!_loggedFormat) {
        NSLog(@"[SUR-REC][ios] audio pcm sampleRate=%.0f channels=%u frames=%u sourceFlags=%u sourceBits=%u",
              streamDescription.mSampleRate,
              (unsigned int)channelCount,
              (unsigned int)frameLength,
              (unsigned int)sourceDescription->mFormatFlags,
              (unsigned int)sourceDescription->mBitsPerChannel);
        _loggedFormat = YES;
    }

    CMAudioFormatDescriptionRef formatDesc = NULL;
    OSStatus formatStatus = CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                                            &streamDescription,
                                                            0,
                                                            nil,
                                                            0,
                                                            nil,
                                                            nil,
                                                            &formatDesc);
    if (formatStatus != noErr || formatDesc == NULL) {
        NSLog(@"[SUR-REC][ios] audio format create failed status=%d", (int)formatStatus);
        return;
    }

    [self updateFormatIfNeeded:formatDesc];

    CMSampleBufferRef buffer = NULL;
    CMSampleTimingInfo timing = [self nextAudioTimingWithSampleRate:(int)streamDescription.mSampleRate
                                                     numberOfFrames:frameLength];
    OSStatus bufferStatus = CMSampleBufferCreate(kCFAllocatorDefault,
                                                  NULL,
                                                  false,
                                                  NULL,
                                                  NULL,
                                                  formatDesc,
                                                  frameLength,
                                                  1,
                                                  &timing,
                                                  0,
                                                  NULL,
                                                  &buffer);
    OSStatus dataStatus = bufferStatus;
    OSStatus blockStatus = noErr;
    CMBlockBufferRef blockBuffer = NULL;
    if (bufferStatus == noErr && buffer != NULL) {
        blockStatus = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         NULL,
                                                         interleavedData.length,
                                                         kCFAllocatorDefault,
                                                         NULL,
                                                         0,
                                                         interleavedData.length,
                                                         0,
                                                         &blockBuffer);
        if (blockStatus == noErr && blockBuffer != NULL) {
            blockStatus = CMBlockBufferReplaceDataBytes(target,
                                                        blockBuffer,
                                                        0,
                                                        interleavedData.length);
        }
        dataStatus = blockStatus;
        if (dataStatus == noErr && blockBuffer != NULL) {
            dataStatus = CMSampleBufferSetDataBuffer(buffer, blockBuffer);
        }
    }
    if (dataStatus == noErr && buffer != NULL) {
        dataStatus = CMSampleBufferSetDataReady(buffer);
    }
    if (dataStatus == noErr && buffer != NULL && self.bufferCallback != nil) {
        self.bufferCallback(buffer);
    } else {
        _dataBufferErrorCount++;
        if (_dataBufferErrorCount <= 3 || _dataBufferErrorCount % 100 == 0) {
            NSLog(@"[SUR-REC][ios] audio sample buffer create failed #%d createStatus=%d blockStatus=%d dataStatus=%d",
                  _dataBufferErrorCount,
                  (int)bufferStatus,
                  (int)blockStatus,
                  (int)dataStatus);
        }
    }

    if (blockBuffer != NULL) {
        CFRelease(blockBuffer);
    }
    if (buffer != NULL) {
        CFRelease(buffer);
    }
    if (formatDesc != NULL) {
        CFRelease(formatDesc);
    }
}

@end
