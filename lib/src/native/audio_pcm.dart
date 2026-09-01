import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'utils.dart';

/// A copied block of PCM from the device microphone.
class RTCAudioPcmFrame {
  const RTCAudioPcmFrame({
    required this.trackId,
    required this.data,
    required this.bitsPerSample,
    required this.sampleRate,
    required this.channels,
    required this.frames,
    this.timestampMs,
  });

  final String trackId;
  final Uint8List data;
  final int bitsPerSample;
  final int sampleRate;
  final int channels;
  final int frames;
  final int? timestampMs;

  Float32List toFloat32List() {
    if (bitsPerSample == 32) {
      final values = Float32List(data.length ~/ 4);
      final bytes = ByteData.sublistView(data);
      for (var index = 0; index < values.length; index++) {
        values[index] = bytes.getFloat32(index * 4, Endian.little);
      }
      return values;
    }
    if (bitsPerSample == 16) {
      final values = Float32List(data.length ~/ 2);
      final bytes = ByteData.sublistView(data);
      for (var index = 0; index < values.length; index++) {
        values[index] = bytes.getInt16(index * 2, Endian.little) / 32768.0;
      }
      return values;
    }
    if (bitsPerSample == 8) {
      final values = Float32List(data.length);
      for (var index = 0; index < values.length; index++) {
        values[index] = (data[index] - 128) / 128.0;
      }
      return values;
    }
    throw UnsupportedError('Unsupported PCM depth: $bitsPerSample');
  }
}

/// Optional PCM access for device-side microphone analysis/recording.
/// Darwin reuses the WebRTC audio device module and keeps its recording input
/// prepared while a listener is attached. The track ID is retained only as the
/// stream identity for the Dart event payload and does not create or modify a
/// PeerConnection.
class RTCLocalAudioPcmCapture {
  RTCLocalAudioPcmCapture._();

  static const EventChannel _eventChannel = EventChannel(
    'FlutterWebRTC.AudioPcm',
  );

  static Stream<RTCAudioPcmFrame> get frames =>
      _eventChannel.receiveBroadcastStream().map(_decodeFrame);

  static Future<void> start(MediaStreamTrack track) async {
    if (track.kind != 'audio') {
      throw ArgumentError('PCM capture requires an audio track');
    }
    await WebRTC.invokeMethod<void, dynamic>(
      'startLocalAudioPcmCapture',
      <String, dynamic>{
        'trackId': track.id,
      },
    );
  }

  static Future<void> stop(MediaStreamTrack track) {
    return WebRTC.invokeMethod<void, dynamic>(
      'stopLocalAudioPcmCapture',
      <String, dynamic>{
        'trackId': track.id,
      },
    );
  }

  static RTCAudioPcmFrame _decodeFrame(dynamic raw) {
    final map = Map<dynamic, dynamic>.from(raw as Map);
    final rawData = map['data'];
    final data = rawData is Uint8List
        ? rawData
        : Uint8List.fromList(List<int>.from(rawData as List));
    return RTCAudioPcmFrame(
      trackId: map['trackId']?.toString() ?? '',
      data: data,
      bitsPerSample: _intValue(map['bitsPerSample']),
      sampleRate: _intValue(map['sampleRate']),
      channels: _intValue(map['channels']),
      frames: _intValue(map['frames']),
      timestampMs:
          map['timestampMs'] == null ? null : _intValue(map['timestampMs']),
    );
  }
}

int _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
