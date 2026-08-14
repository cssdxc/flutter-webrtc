package com.cloudwebrtc.webrtc;

import android.app.Activity;
import android.app.PictureInPictureParams;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.util.Rational;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.util.HashMap;
import java.util.Map;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodCall;

/**
 * Android system PiP controller for the Flutter Activity.
 *
 * Android PiP keeps the Activity's existing Flutter/WebRTC texture alive, so
 * it does not need a second WebRTC renderer like the iOS implementation.
 */
final class FlutterRTCPictureInPictureController {
  private static final String TAG = "FlutterWebRTCPlugin";
  private static final String CHANNEL_NAME = "FlutterWebRTC.PictureInPicture";
  private static final long STATE_POLL_INTERVAL_MS = 250L;

  private final MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private final Runnable statePoller = new Runnable() {
    @Override
    public void run() {
      final Activity currentActivity = activity;
      if (currentActivity == null) {
        stopStatePolling();
        return;
      }

      final boolean active = isActive(currentActivity);
      sendStateIfChanged(active);
      if (active || lastState) {
        mainHandler.postDelayed(this, STATE_POLL_INTERVAL_MS);
      } else {
        stopStatePolling();
      }
    }
  };

  @Nullable
  private Activity activity;
  private boolean lastState;
  private boolean polling;

  FlutterRTCPictureInPictureController(@NonNull BinaryMessenger messenger) {
    channel = new MethodChannel(messenger, CHANNEL_NAME);
  }

  void setActivity(@Nullable Activity activity) {
    this.activity = activity;
    if (activity == null) {
      sendStateIfChanged(false);
      stopStatePolling();
    } else if (isActive(activity)) {
      startStatePolling();
    }
  }

  void isSupported(@NonNull MethodChannel.Result result) {
    final Activity currentActivity = activity;
    final boolean supported = currentActivity != null
        && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        && currentActivity.getPackageManager().hasSystemFeature(
            PackageManager.FEATURE_PICTURE_IN_PICTURE);
    Log.d(TAG, "FlutterWebRTC PiP Android isSupported=" + supported);
    result.success(supported);
  }

  void isActive(@NonNull MethodChannel.Result result) {
    result.success(activity != null && isActive(activity));
  }

  void start(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    final Activity currentActivity = activity;
    if (currentActivity == null) {
      result.error("pipStart", "Activity is unavailable", null);
      return;
    }
    if (!isSupported(currentActivity)) {
      result.error("pipStart", "Android system PiP is not supported", null);
      return;
    }

    currentActivity.runOnUiThread(() -> {
      try {
        final PictureInPictureParams params = new PictureInPictureParams.Builder()
            .setAspectRatio(aspectRatio(call))
            .build();
        final boolean entered = currentActivity.enterPictureInPictureMode(params);
        Log.d(TAG, "FlutterWebRTC PiP Android start entered=" + entered);
        if (!entered) {
          result.error("pipStart", "Activity rejected PiP request", null);
          return;
        }
        sendStateIfChanged(true);
        startStatePolling();
        result.success(null);
      } catch (Exception error) {
        Log.e(TAG, "FlutterWebRTC PiP Android start failed", error);
        result.error("pipStart", error.getMessage(), null);
      }
    });
  }

  void stop(@NonNull MethodChannel.Result result) {
    // Android has no public API equivalent to iOS stopPictureInPicture.
    // The system close/expand actions end or restore the Activity instead.
    Log.d(TAG, "FlutterWebRTC PiP Android stop requested");
    result.success(null);
  }

  void dispose(@NonNull MethodChannel.Result result) {
    if (!isActive()) {
      stopStatePolling();
    }
    Log.d(TAG, "FlutterWebRTC PiP Android dispose");
    result.success(null);
  }

  void debugState(@NonNull MethodChannel.Result result) {
    final Map<String, Object> state = new HashMap<>();
    state.put("platform", "android");
    state.put("supported", activity != null && isSupported(activity));
    state.put("active", isActive());
    state.put("api", Build.VERSION.SDK_INT);
    result.success(state);
  }

  void disposeController() {
    stopStatePolling();
    channel.setMethodCallHandler(null);
  }

  private boolean isSupported(@NonNull Activity currentActivity) {
    return Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        && currentActivity.getPackageManager().hasSystemFeature(
            PackageManager.FEATURE_PICTURE_IN_PICTURE);
  }

  private boolean isActive() {
    return activity != null && isActive(activity);
  }

  private boolean isActive(@NonNull Activity currentActivity) {
    return Build.VERSION.SDK_INT >= Build.VERSION_CODES.N
        && currentActivity.isInPictureInPictureMode();
  }

  private Rational aspectRatio(@NonNull MethodCall call) {
    final Integer width = call.argument("aspectRatioWidth");
    final Integer height = call.argument("aspectRatioHeight");
    if (width != null && height != null && width > 0 && height > 0) {
      return new Rational(width, height);
    }
    return new Rational(16, 9);
  }

  private void startStatePolling() {
    if (polling) return;
    polling = true;
    mainHandler.post(statePoller);
  }

  private void stopStatePolling() {
    polling = false;
    mainHandler.removeCallbacks(statePoller);
  }

  private void sendStateIfChanged(boolean active) {
    if (lastState == active) return;
    lastState = active;
    final Map<String, Object> arguments = new HashMap<>();
    arguments.put("active", active);
    channel.invokeMethod("stateChanged", arguments);
    Log.d(TAG, "FlutterWebRTC PiP Android stateChanged active=" + active);
  }
}
