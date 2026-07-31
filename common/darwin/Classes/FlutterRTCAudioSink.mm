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

    AVAudioFrameCount frameLength = pcmBuffer.frameLength;

    if (!_loggedFormat) {
        NSLog(@"[SUR-REC][ios] audio pcm sampleRate=%.0f channels=%u frames=%u sourceFlags=%u sourceBits=%u",
              sourceDescription->mSampleRate,
              (unsigned int)sourceDescription->mChannelsPerFrame,
              (unsigned int)frameLength,
              (unsigned int)sourceDescription->mFormatFlags,
              (unsigned int)sourceDescription->mBitsPerChannel);
        _loggedFormat = YES;
    }

    CMAudioFormatDescriptionRef formatDesc = NULL;
    OSStatus formatStatus = CMAudioFormatDescriptionCreate(kCFAllocatorDefault,
                                                            sourceDescription,
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
    CMSampleTimingInfo timing = [self nextAudioTimingWithSampleRate:(int)sourceDescription->mSampleRate
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
    if (dataStatus == noErr && buffer != NULL) {
        dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            buffer,
            kCFAllocatorDefault,
            kCFAllocatorDefault,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            pcmBuffer.audioBufferList);
    }
    if (dataStatus == noErr && buffer != NULL) {
        dataStatus = CMSampleBufferSetDataReady(buffer);
    }
    if (dataStatus == noErr && buffer != NULL && self.bufferCallback != nil) {
        self.bufferCallback(buffer);
    } else {
        _dataBufferErrorCount++;
        if (_dataBufferErrorCount <= 3 || _dataBufferErrorCount % 100 == 0) {
            NSLog(@"[SUR-REC][ios] audio sample buffer create failed #%d createStatus=%d dataStatus=%d",
                  _dataBufferErrorCount,
                  (int)bufferStatus,
                  (int)dataStatus);
        }
    }

    if (buffer != NULL) {
        CFRelease(buffer);
    }
    if (formatDesc != NULL) {
        CFRelease(formatDesc);
    }
}

@end