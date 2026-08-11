import 'dart:async';

import 'package:webrtc_interface/webrtc_interface.dart';

class WebRTCPictureInPicture {
  const WebRTCPictureInPicture._();

  static void setRestoreUserInterfaceHandler(
    FutureOr<bool> Function()? handler,
  ) {}

  static void setStateChangedHandler(
    FutureOr<void> Function(bool active)? handler,
  ) {}

  static Future<bool> isSupported() async => false;

  static Future<bool> isActive() async => false;

  static Future<void> prepare(
    MediaStreamTrack track, {
    required int sourceViewId,
  }) async {}

  static Future<void> start(
    MediaStreamTrack track, {
    int? sourceViewId,
  }) async {}

  static Future<void> stop() async {}

  static Future<void> updateTrack(MediaStreamTrack track) async {}

  static Future<void> dispose() async {}
}
