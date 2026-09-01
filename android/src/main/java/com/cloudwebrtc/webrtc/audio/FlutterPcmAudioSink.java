package com.cloudwebrtc.webrtc.audio;

import java.nio.ByteBuffer;
import java.io.ByteArrayOutputStream;
import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.EventChannel;

/** Forwards local WebRTC microphone PCM to Flutter without changing the track. */
public final class FlutterPcmAudioSink implements org.webrtc.AudioTrackSink {
    private final EventChannel.EventSink eventSink;
    private final String trackId;
    private final ByteArrayOutputStream pending = new ByteArrayOutputStream();
    private volatile boolean closed;
    private int pendingBitsPerSample;
    private int pendingSampleRate;
    private int pendingChannels;

    public FlutterPcmAudioSink(EventChannel.EventSink eventSink, String trackId) {
        this.eventSink = eventSink;
        this.trackId = trackId;
    }

    @Override
    public synchronized void onData(
            ByteBuffer data,
            int bitsPerSample,
            int sampleRate,
            int numberOfChannels,
            int numberOfFrames,
            long absoluteCaptureTimestampMs) {
        if (closed || data == null) return;
        if (bitsPerSample <= 0 || sampleRate <= 0 || numberOfChannels <= 0) return;
        if (pendingSampleRate != sampleRate || pendingChannels != numberOfChannels ||
                pendingBitsPerSample != bitsPerSample) {
            pending.reset();
            pendingSampleRate = sampleRate;
            pendingChannels = numberOfChannels;
            pendingBitsPerSample = bitsPerSample;
        }
        ByteBuffer copy = data.duplicate();
        byte[] bytes = new byte[copy.remaining()];
        copy.get(bytes);
        pending.write(bytes, 0, bytes.length);

        int bytesPerSample = Math.max(1, bitsPerSample / 8);
        int targetFrames = Math.max(1, sampleRate / 10);
        int targetBytes = targetFrames * numberOfChannels * bytesPerSample;
        while (pending.size() >= targetBytes && !closed) {
            byte[] buffered = pending.toByteArray();
            byte[] chunk = new byte[targetBytes];
            System.arraycopy(buffered, 0, chunk, 0, targetBytes);
            pending.reset();
            if (buffered.length > targetBytes) {
                pending.write(buffered, targetBytes, buffered.length - targetBytes);
            }
            Map<String, Object> event = new HashMap<>();
            event.put("trackId", trackId);
            event.put("data", chunk);
            event.put("bitsPerSample", bitsPerSample);
            event.put("sampleRate", sampleRate);
            event.put("channels", numberOfChannels);
            event.put("frames", targetFrames);
            event.put("timestampMs", absoluteCaptureTimestampMs);
            eventSink.success(event);
        }
    }

    public synchronized void close() {
        closed = true;
        pending.reset();
    }
}
