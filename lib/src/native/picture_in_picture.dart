import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_track_impl.dart';
import 'utils.dart';

class WebRTCPictureInPicture {
  const WebRTCPictureInPicture._();

  static const MethodChannel _eventChannel = MethodChannel(
    'FlutterWebRTC.PictureInPicture',
  );
  static FutureOr<bool> Function()? _restoreUserInterfaceHandler;
  static FutureOr<void> Function(bool active)? _stateChangedHandler;
  static bool _isEventChannelInitialized = false;

  static void setRestoreUserInterfaceHandler(
    FutureOr<bool> Function()? handler,
  ) {
    _restoreUserInterfaceHandler = handler;
    _ensureEventChannelInitialized();
  }

  static void setStateChangedHandler(
    FutureOr<void> Function(bool active)? handler,
  ) {
    _stateChangedHandler = handler;
    _ensureEventChannelInitialized();
  }

  static void _ensureEventChannelInitialized() {
    if (kIsWeb ||
        (!Platform.isIOS && !Platform.isAndroid) ||
        _isEventChannelInitialized) {
      return;
    }
    _isEventChannelInitialized = true;
    _eventChannel.setMethodCallHandler(_handleEventChannelCall);
  }

  static Future<dynamic> _handleEventChannelCall(MethodCall call) async {
    if (call.method == 'stateChanged') {
      final arguments = call.arguments;
      final active =
          arguments is Map ? arguments['active'] == true : arguments == true;
      await _stateChangedHandler?.call(active);
      return null;
    }
    if (call.method != 'restoreUserInterface') return false;
    final handler = _restoreUserInterfaceHandler;
    if (handler == null) {
      return false;
    }
    return await handler();
  }

  static Future<bool> isSupported() async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      debugPrint('FlutterWebRTC PiP isSupported=false: unsupported platform');
      return false;
    }
    final supported =
        await WebRTC.invokeMethod<bool, dynamic>('pipIsSupported') ?? false;
    debugPrint('FlutterWebRTC PiP isSupported=$supported');
    return supported;
  }

  static Future<bool> isActive() async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      return false;
    }
    return await WebRTC.invokeMethod<bool, dynamic>('pipIsActive') ?? false;
  }

  static Future<void> prepare(
    MediaStreamTrack track, {
    required int sourceViewId,
  }) async {
    if (kIsWeb || !Platform.isIOS || track.kind != 'video') {
      return;
    }
    debugPrint(
      'FlutterWebRTC PiP prepare: trackId=${track.id}, '
      'sourceViewId=$sourceViewId',
    );
    await WebRTC.invokeMethod<void, dynamic>('pipPrepare', <String, dynamic>{
      'trackId': track.id,
      'peerConnectionId':
          track is MediaStreamTrackNative ? track.peerConnectionId : null,
      'sourceViewId': sourceViewId,
    });
    debugPrint('FlutterWebRTC PiP prepared: ${await debugState()}');
  }

  static Future<void> start(MediaStreamTrack track, {int? sourceViewId}) async {
    if (kIsWeb ||
        (!Platform.isIOS && !Platform.isAndroid) ||
        track.kind != 'video') {
      debugPrint(
        'FlutterWebRTC PiP start ignored: '
        'isWeb=$kIsWeb, isIOS=${!kIsWeb && Platform.isIOS}, '
        'isAndroid=${!kIsWeb && Platform.isAndroid}, kind=${track.kind}',
      );
      return;
    }

    debugPrint('FlutterWebRTC PiP start: trackId=${track.id}');
    await WebRTC.invokeMethod<void, dynamic>(
      'pipStart',
      <String, dynamic>{
        'trackId': track.id,
        'peerConnectionId':
            track is MediaStreamTrackNative ? track.peerConnectionId : null,
        'sourceViewId': sourceViewId,
      },
    );
  }

  static Future<void> updateTrack(MediaStreamTrack track) async {
    if (kIsWeb || !Platform.isIOS || track.kind != 'video') return;
    await WebRTC.invokeMethod<void, dynamic>(
      'pipUpdateTrack',
      <String, dynamic>{
        'trackId': track.id,
        'peerConnectionId':
            track is MediaStreamTrackNative ? track.peerConnectionId : null,
      },
    );
  }

  static Future<Map<dynamic, dynamic>> debugState() async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      return <dynamic, dynamic>{'event': 'unsupportedPlatform'};
    }
    return await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
          'pipDebugState',
        ) ??
        <dynamic, dynamic>{'event': 'unavailable'};
  }

  static Future<void> stop() async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      return;
    }
    await WebRTC.invokeMethod<void, dynamic>('pipStop');
  }

  static Future<void> dispose() async {
    if (kIsWeb || (!Platform.isIOS && !Platform.isAndroid)) {
      return;
    }
    await WebRTC.invokeMethod<void, dynamic>('pipDispose');
  }
}
