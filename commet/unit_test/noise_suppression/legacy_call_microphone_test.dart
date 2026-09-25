// A legacy 1:1 call (matrix-dart-sdk) captures its microphone through
// MatrixVoipComponent.mediaDevices with its own fixed constraints: WebRTC's
// noise suppressor on, no device. NoiseSuppressedMediaDevices makes it a
// microphone like any other: the preference decides who suppresses, the
// picked device is used, and on the web the stream goes through the DSP.
import 'package:commet/client/components/voip/audio_processing/audio_processing_manager_stub.dart';
import 'package:commet/client/components/voip/audio_processing/noise_suppressed_media_devices.dart';
import 'package:commet/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

class _Track implements MediaStreamTrack {
  @override
  final String kind;
  bool stopped = false;
  _Track(this.kind);

  @override
  Future<void> stop() async => stopped = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stream implements MediaStream {
  final List<_Track> tracks;
  bool disposed = false;
  _Stream(this.tracks);

  @override
  List<MediaStreamTrack> getTracks() => tracks;

  @override
  List<MediaStreamTrack> getAudioTracks() =>
      tracks.where((t) => t.kind == 'audio').toList();

  @override
  Future<void> dispose() async => disposed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Devices implements MediaDevices {
  final List<Map<String, dynamic>> calls = [];
  final List<_Stream> streams = [];

  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) async {
    calls.add(constraints);
    final s = _Stream([_Track('audio')]);
    streams.add(s);
    return s;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Dsp extends UnsupportedAudioProcessingManager {
  bool supported = true;

  /// What processMicrophoneStream hands back: the stream itself (desktop),
  /// another one (the web's processed stream), or nothing (the web's DSP
  /// failed to start).
  MediaStream? Function(MediaStream)? process;

  @override
  bool get isSupported => supported;

  @override
  Future<MediaStream?> processMicrophoneStream(MediaStream stream) async =>
      process == null ? stream : process!(stream);
}

/// The SDK's UserMediaConstraints.micMediaConstraints.
const _sdkMic = {
  'audio': {
    'echoCancellation': true,
    'noiseSuppression': true,
    'autoGainControl': false,
  },
  'video': false,
};

List<Map> _optional(Map<String, dynamic> call) =>
    ((call['audio'] as Map)['optional'] as List).cast<Map>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Devices devices;
  late _Dsp dsp;
  late bool preference;
  late NoiseSuppressedMediaDevices wrapped;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await preferences.init();
  });

  setUp(() {
    devices = _Devices();
    dsp = _Dsp();
    preference = true;
    wrapped = NoiseSuppressedMediaDevices(devices,
        dsp: () => dsp,
        preference: () => preference,
        deviceId: () async => 'picked-mic');
  });

  tearDown(() => dsp.dispose());

  test('ours running: WebRTC\'s suppressor off, the picked microphone',
      () async {
    final stream = await wrapped.getUserMedia(_sdkMic);

    expect(
        _optional(devices.calls.single),
        containsAll([
          equals({'noiseSuppression': false}),
          equals({'sourceId': 'picked-mic'}),
        ]));
    expect(devices.calls.single['video'], isFalse);
    expect(stream, same(devices.streams.single));
  });

  test('without our DSP, or with the preference off, WebRTC\'s stays on',
      () async {
    dsp.supported = false;
    await wrapped.getUserMedia(_sdkMic);
    dsp.supported = true;
    preference = false;
    await wrapped.getUserMedia(_sdkMic);

    for (final call in devices.calls) {
      expect(_optional(call), contains(equals({'noiseSuppression': true})));
    }
  });

  test('the web sends what the DSP makes of the microphone', () async {
    final processed = _Stream([_Track('audio')]);
    dsp.process = (_) => processed;

    expect(await wrapped.getUserMedia(_sdkMic), same(processed));
  });

  // The capture asked for WebRTC's suppressor to be off: sending it raw
  // would send the noise.
  test('if ours cannot start, the call captures again with WebRTC\'s',
      () async {
    dsp.process = (_) => null;

    final stream = await wrapped.getUserMedia(_sdkMic);

    expect(devices.calls, hasLength(2));
    expect(_optional(devices.calls.last),
        contains(equals({'noiseSuppression': true})));
    expect(stream, same(devices.streams.last));
    expect(devices.streams.first.tracks.single.stopped, isTrue);
    expect(devices.streams.first.disposed, isTrue);
  });

  test('a capture without audio is left alone', () async {
    final video = {'audio': false, 'video': true};
    await wrapped.getUserMedia(video);
    expect(devices.calls.single, same(video));
  });
}
