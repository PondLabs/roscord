// Linux and Windows: the voice DSP runs inside WebRTC's audio processing
// module, installed through the vendored LiveKit plugin. These put the
// fixture through NativeAudioProcessingManager as the app runs it: the real
// DSP library, the struct layouts and callback addresses the manager hands
// the plugin, and the plugin's host (fake_livekit_plugin.dart) calling them
// the way the APM does. What comes out is what would be encoded and sent.
@TestOn('linux')
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:commet/client/components/voip/audio_processing/audio_processing_manager_native.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_livekit_plugin.dart';
import 'fakes.dart';
import 'voice_dsp_fixture.dart';

typedef _AllocNative = Pointer<Float> Function(Size);
typedef _Alloc = Pointer<Float> Function(int);
typedef _FreeNative = Void Function(Pointer<Float>, Size);
typedef _Free = void Function(Pointer<Float>, int);

class _Session implements VoipSession {
  final String name;
  _Session(this.name);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  String toString() => '_Session($name)';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeLivekitPlugin plugin;
  late FakeWebrtcChannel webrtc;
  late NativeAudioProcessingManager manager;
  late NoisySpeech fixture;
  late _Alloc alloc;
  late _Free free;

  setUpAll(() async {
    if (voiceDspSkip != false) return;
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await preferences.init();
    fixture = NoisySpeech.load();
    final lib = DynamicLibrary.open(dspLibraryPath);
    alloc = lib.lookupFunction<_AllocNative, _Alloc>('commet_dsp_alloc_f32');
    free = lib.lookupFunction<_FreeNative, _Free>('commet_dsp_free_f32');
  });

  setUp(() async {
    await preferences.voipNoiseSuppression.set(true);
    await preferences.voipInputSensitivityAuto.set(true);
    plugin = FakeLivekitPlugin()..install();
    webrtc = FakeWebrtcChannel()..install();
    manager = NativeAudioProcessingManager(
        openLibrary: () => DynamicLibrary.open(dspLibraryPath));
  });

  tearDown(() {
    manager.dispose();
    plugin.uninstall();
    webrtc.uninstall();
  });

  Float32List send(Float32List input) =>
      plugin.processCapture(input, alloc: alloc, free: free);

  test('the hook takes the room noise out and leaves the voice', () async {
    await manager.onSessionStarted(_Session('call'));
    plugin.initialize(48000);

    final m = measure(fixture.samples, send(fixture.samples), fixture.labels);

    expect(m.noiseDropDb, greaterThanOrEqualTo(minNoiseDropDb), reason: '$m');
    expect(m.speechChangeDb, greaterThanOrEqualTo(-maxSpeechLossDb),
        reason: '$m');
  }, skip: voiceDspSkip);

  // The loop can tell: with suppression and the automatic gate off, the
  // noise has to come through. The preference change also has to reach the
  // DSP that is already running, in both directions.
  test('the noise suppression preference reaches the running DSP', () async {
    await manager.onSessionStarted(_Session('call'));
    plugin.initialize(48000);

    await preferences.voipNoiseSuppression.set(false);
    await preferences.voipInputSensitivityAuto.set(false);
    await pumpEventQueue();
    final off = measure(fixture.samples, send(fixture.samples), fixture.labels);
    expect(off.noiseDropDb, lessThan(3), reason: 'with everything off: $off');

    await preferences.voipNoiseSuppression.set(true);
    await preferences.voipInputSensitivityAuto.set(true);
    await pumpEventQueue();
    final on = measure(fixture.samples, send(fixture.samples), fixture.labels);
    expect(on.noiseDropDb, greaterThanOrEqualTo(minNoiseDropDb),
        reason: 'turned back on: $on');
  }, skip: voiceDspSkip);

  test('isProcessing follows the audio the hook actually gets', () async {
    await manager.onSessionStarted(_Session('call'));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(manager.isProcessing, isFalse,
        reason: 'no audio has reached the hook yet');

    plugin.initialize(48000);
    send(Float32List.sublistView(fixture.samples, 0, 48000));
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(manager.isProcessing, isTrue);
  }, skip: voiceDspSkip);

  test('a library without the DSP is not taken for one', () {
    final other = NativeAudioProcessingManager(
        openLibrary: () => DynamicLibrary.process());
    expect(other.isSupported, isFalse);
    other.dispose();
  }, skip: voiceDspSkip);

  // Every entry point is looked up when the library loads: a missing one
  // found only at install time left WebRTC's suppressor off (the join had
  // already asked for that) with nothing of ours on the hook.
  test('a library missing a callback is not taken for the DSP', () {
    Pointer<T> withoutCapture<T extends NativeType>(
        DynamicLibrary library, String name) {
      if (name == 'commet_dsp_capture_process') {
        throw ArgumentError('undefined symbol: $name');
      }
      return library.lookup<T>(name);
    }

    final partial = NativeAudioProcessingManager(
        openLibrary: () => DynamicLibrary.open(dspLibraryPath),
        symbols: withoutCapture);
    expect(partial.isSupported, isFalse);
    partial.dispose();
  }, skip: voiceDspSkip);
}
