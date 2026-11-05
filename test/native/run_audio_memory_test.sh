#!/bin/bash
set -euo pipefail
plugin_root="$(cd "$(dirname "$0")/../.." && pwd)"
framework_dir="${1:?Pass the directory containing the macOS WebRTC.framework (the macos-arm64_x86_64 slice of WebRTC.xcframework)}"
framework_dir="$(cd "$framework_dir" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/webrtc-audio-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
python3 - "$plugin_root" "$test_dir" <<'PY'
from pathlib import Path
import sys
root, output = map(Path, sys.argv[1:])
source = (root / 'common/darwin/Classes/FlutterWebRTCPlugin.m').read_text()
start = source.index('    __weak FlutterWebRTCPlugin* weakSelf = self;',
                     source.index('startLocalAudioPcmCapture" isEqualToString:call.method'))
end = source.index('    _pcmAudioSinks[trackId] = sink;', start)
# Compile the real production callback in a minimal engine-free owner, so the
# queue lifecycle tests cannot silently drift into a separate implementation.
(output / 'pcm_event_callback.inc').write_text(source[start:end])
PY
xcrun clang++ -x objective-c++ -fobjc-arc -std=c++14 -Wno-nullability-completeness \
  -Wno-incomplete-implementation -Wno-objc-property-implementation \
  -I "$plugin_root/common/darwin/Classes" -I "$test_dir" -F "$framework_dir" \
  -framework WebRTC -framework Foundation -framework AVFoundation -framework CoreMedia \
  -Wl,-rpath,"$framework_dir" \
  "$plugin_root/test/native/audio_memory_test.mm" \
  "$plugin_root/common/darwin/Classes/FlutterRTCAudioSink.mm" \
  "$plugin_root/common/darwin/Classes/AudioProcessingAdapter.m" \
  -o "$test_dir/audio_memory_test"
"$test_dir/audio_memory_test"
