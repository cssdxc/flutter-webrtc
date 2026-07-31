#include "media_stream_interface.h"
#include "FlutterRTCAudioSink-Interface.h"
#include <atomic>

class AudioSinkBridge : public webrtc::AudioTrackSinkInterface {
private:
    void* sink;
    std::atomic<bool> closed;

public:
    AudioSinkBridge(void* sink1) {
        sink = sink1;
        closed.store(false, std::memory_order_release);
    }
    void Close() {
        closed.store(true, std::memory_order_release);
    }
    void OnData(const void* audio_data,
                        int bits_per_sample,
                        int sample_rate,
                        size_t number_of_channels,
                        size_t number_of_frames) override
    {
        if (closed.load(std::memory_order_acquire) || sink == nullptr) {
            return;
        }
        RTCAudioSinkCallback(sink,
                             audio_data,
                             bits_per_sample,
                             sample_rate,
                             number_of_channels,
                             number_of_frames
        );
    };
    int NumPreferredChannels() const override { return 1; }
};
