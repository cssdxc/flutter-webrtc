package com.cloudwebrtc.webrtc.audio;

import android.Manifest;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;

import org.webrtc.audio.JavaAudioDeviceModule;

import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

import io.flutter.plugin.common.EventChannel;

/**
 * Keeps device-side PCM available without requiring a PeerConnection.
 * WebRTC capture has priority; the standalone AudioRecord runs only while the
 * WebRTC audio device is not producing microphone samples.
 */
public final class StandaloneAudioCaptureController
        implements JavaAudioDeviceModule.SamplesReadyCallback {
    private static final String TAG = "FlutterPcmCapture";
    private static final int SAMPLE_RATE = 16000;
    private static final int CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO;
    private static final int AUDIO_FORMAT = AudioFormat.ENCODING_PCM_16BIT;
    private static final long WEBRTC_STALE_MS = 1200;
    private static final long WEBRTC_START_GRACE_MS = 3000;

    private final Context context;
    private final Object lock = new Object();
    private final ScheduledExecutorService controlExecutor =
            Executors.newSingleThreadScheduledExecutor();

    private FlutterPcmAudioSink sink;
    private String trackId;
    private AudioRecord standaloneRecord;
    private JavaAudioDeviceModule.SamplesReadyCallback standaloneSamplesCallback;
    private volatile long lastWebRtcFrameAtMs;
    private volatile long standaloneSuppressedUntilMs;
    private volatile boolean disposed;

    public StandaloneAudioCaptureController(Context context) {
        this.context = context.getApplicationContext();
        controlExecutor.scheduleWithFixedDelay(
                this::ensureCaptureSource,
                0,
                500,
                TimeUnit.MILLISECONDS);
    }

    public void start(String requestedTrackId, EventChannel.EventSink eventSink) {
        if (requestedTrackId == null || requestedTrackId.trim().isEmpty()) {
            throw new IllegalArgumentException("PCM capture requires a track ID");
        }
        synchronized (lock) {
            if (disposed) throw new IllegalStateException("PCM capture is disposed");
            if (sink != null) sink.close();
            trackId = requestedTrackId;
            sink = new FlutterPcmAudioSink(eventSink, requestedTrackId);
        }
        controlExecutor.execute(this::ensureCaptureSource);
    }

    public void setStandaloneSamplesCallback(
            JavaAudioDeviceModule.SamplesReadyCallback callback) {
        standaloneSamplesCallback = callback;
    }

    public void stop(String requestedTrackId) {
        synchronized (lock) {
            if (trackId == null || !trackId.equals(requestedTrackId)) return;
            if (sink != null) sink.close();
            sink = null;
            trackId = null;
        }
        controlExecutor.execute(this::stopStandaloneCapture);
    }

    public void stopAll() {
        synchronized (lock) {
            if (sink != null) sink.close();
            sink = null;
            trackId = null;
        }
        stopStandaloneCapture();
    }

    /** Release the standalone microphone before WebRTC starts its AudioRecord. */
    public void prepareForWebRtcCapture() {
        standaloneSuppressedUntilMs =
                SystemClock.elapsedRealtime() + WEBRTC_START_GRACE_MS;
        stopStandaloneCapture();
    }

    @Override
    public void onWebRtcAudioRecordSamplesReady(
            JavaAudioDeviceModule.AudioSamples audioSamples) {
        if (disposed || audioSamples == null) return;
        final long now = SystemClock.elapsedRealtime();
        lastWebRtcFrameAtMs = now;
        standaloneSuppressedUntilMs = now + WEBRTC_STALE_MS;
        synchronized (lock) {
            if (standaloneRecord != null) {
                controlExecutor.execute(this::stopStandaloneCapture);
            }
            if (sink == null) return;
            int bytesPerSample = bytesPerSample(audioSamples.getAudioFormat());
            int channels = Math.max(1, audioSamples.getChannelCount());
            byte[] data = audioSamples.getData();
            int frames = data.length / Math.max(1, bytesPerSample * channels);
            sink.onData(
                    ByteBuffer.wrap(data),
                    bytesPerSample * 8,
                    audioSamples.getSampleRate(),
                    channels,
                    frames,
                    now);
        }
    }

    public void dispose() {
        disposed = true;
        stopAll();
        controlExecutor.shutdownNow();
    }

    private void ensureCaptureSource() {
        if (disposed) return;
        final long now = SystemClock.elapsedRealtime();
        synchronized (lock) {
            if (sink == null || standaloneRecord != null) return;
            if (now < standaloneSuppressedUntilMs ||
                    now - lastWebRtcFrameAtMs < WEBRTC_STALE_MS) {
                return;
            }
        }
        startStandaloneCapture();
    }

    private void startStandaloneCapture() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) !=
                        PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "Standalone PCM capture skipped: RECORD_AUDIO denied");
            return;
        }
        final int minimumBuffer = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                CHANNEL_CONFIG,
                AUDIO_FORMAT);
        if (minimumBuffer <= 0) {
            Log.w(TAG, "Standalone PCM capture unsupported buffer=" + minimumBuffer);
            return;
        }
        final int readBytes = SAMPLE_RATE / 10 * 2;
        final AudioRecord record;
        try {
            record = new AudioRecord(
                    MediaRecorder.AudioSource.VOICE_RECOGNITION,
                    SAMPLE_RATE,
                    CHANNEL_CONFIG,
                    AUDIO_FORMAT,
                    Math.max(minimumBuffer, readBytes * 2));
            if (record.getState() != AudioRecord.STATE_INITIALIZED) {
                record.release();
                Log.w(TAG, "Standalone PCM AudioRecord failed to initialize");
                return;
            }
            record.startRecording();
        } catch (RuntimeException error) {
            Log.w(TAG, "Standalone PCM capture failed to start", error);
            return;
        }

        synchronized (lock) {
            final long now = SystemClock.elapsedRealtime();
            if (disposed || sink == null || standaloneRecord != null ||
                    now < standaloneSuppressedUntilMs ||
                    now - lastWebRtcFrameAtMs < WEBRTC_STALE_MS) {
                stopAndRelease(record);
                return;
            }
            standaloneRecord = record;
        }
        Log.i(TAG, "Standalone PCM capture started");
        Thread captureThread = new Thread(
                () -> captureLoop(record, readBytes),
                "FlutterPcmAudioRecord");
        captureThread.start();
    }

    private void captureLoop(AudioRecord record, int readBytes) {
        final byte[] buffer = new byte[readBytes];
        while (!disposed) {
            synchronized (lock) {
                if (standaloneRecord != record || sink == null) break;
            }
            final int read;
            try {
                read = record.read(buffer, 0, buffer.length);
            } catch (RuntimeException error) {
                Log.w(TAG, "Standalone PCM read failed", error);
                break;
            }
            if (read <= 0) {
                if (read != AudioRecord.ERROR_INVALID_OPERATION) continue;
                break;
            }
            synchronized (lock) {
                if (standaloneRecord != record || sink == null) break;
                final byte[] captured = Arrays.copyOf(buffer, read);
                sink.onData(
                        ByteBuffer.wrap(captured),
                        16,
                        SAMPLE_RATE,
                        1,
                        read / 2,
                        SystemClock.elapsedRealtime());
                final JavaAudioDeviceModule.SamplesReadyCallback callback =
                        standaloneSamplesCallback;
                if (callback != null) {
                    callback.onWebRtcAudioRecordSamplesReady(
                            new JavaAudioDeviceModule.AudioSamples(
                                    AUDIO_FORMAT,
                                    1,
                                    SAMPLE_RATE,
                                    captured));
                }
            }
        }
        if (!disposed) {
            controlExecutor.execute(() -> releaseIfCurrent(record));
        }
    }

    private void stopStandaloneCapture() {
        final AudioRecord record;
        synchronized (lock) {
            record = standaloneRecord;
            standaloneRecord = null;
        }
        if (record != null) {
            stopAndRelease(record);
            Log.i(TAG, "Standalone PCM capture stopped");
        }
    }

    private void releaseIfCurrent(AudioRecord record) {
        synchronized (lock) {
            if (standaloneRecord != record) return;
            standaloneRecord = null;
        }
        stopAndRelease(record);
    }

    private static void stopAndRelease(AudioRecord record) {
        try {
            if (record.getRecordingState() == AudioRecord.RECORDSTATE_RECORDING) {
                record.stop();
            }
        } catch (RuntimeException ignored) {
        }
        record.release();
    }

    private static int bytesPerSample(int audioFormat) {
        switch (audioFormat) {
            case AudioFormat.ENCODING_PCM_8BIT:
                return 1;
            case AudioFormat.ENCODING_PCM_FLOAT:
                return 4;
            case AudioFormat.ENCODING_PCM_16BIT:
            case AudioFormat.ENCODING_DEFAULT:
            default:
                return 2;
        }
    }
}
