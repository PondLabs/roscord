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

/// Equal by name, the way MatrixVoipSession is equal by call id.
class _Session implements VoipSession {
  final String name;
  _Session(this.name);

  @override
  bool operator ==(Object other) => other is _Session && other.name == name;

  @override
  int get hashCode => name.hashCode;

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

  tearDown(() async {
    for (final name in ['call', 'first', 'second', 'rejoined']) {
      await manager.onSessionEnded(_Session(name));
    }
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

  // The app creates the DSP on the UI thread, so DeepFilterNet's model is
  // built on a thread of its own and RNNoise suppresses meanwhile. The
  // model has to arrive, take over, and take the noise out itself.
  test('DeepFilterNet takes over from RNNoise and suppresses', () async {
    await manager.onSessionStarted(_Session('call'));
    plugin.initialize(48000);
    final block = Float32List.sublistView(fixture.samples, 0, 480);

    send(block);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(manager.lastReport?.noiseSuppressionActive, isTrue);
    for (var i = 0; manager.lastReport?.deepFilterActive != true; i++) {
      if (i == 500) fail('DeepFilterNet did not take over in 5 s');
      send(block);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    final m = measure(fixture.samples, send(fixture.samples), fixture.labels);
    expect(manager.lastReport?.deepFilterActive, isTrue);
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

  // Leaving one voice channel for another: the leave's teardown and the
  // join's install run concurrently (CallManager does not await them).
  test('leaving and joining back to back leaves the DSP on the hook', () async {
    final first = _Session('first');
    await manager.onSessionStarted(first);

    final leave = manager.onSessionEnded(first);
    final join = manager.onSessionStarted(_Session('second'));
    await Future.wait([leave, join]);

    expect(plugin.hasCaptureProcessor, isTrue,
        reason: 'plugin calls: ${plugin.calls}');
    plugin.initialize(48000);
    final m = measure(fixture.samples, send(fixture.samples), fixture.labels);
    expect(m.noiseDropDb, greaterThanOrEqualTo(minNoiseDropDb), reason: '$m');
  }, skip: voiceDspSkip);

  // After an app refresh the old CallManager still sees its own call end,
  // late, while the user is already in the rejoined one.
  test('a call ending does not take the DSP off another call', () async {
    final old = _Session('before the refresh');
    final rejoined = _Session('rejoined');
    await manager.onSessionStarted(old);
    await manager.onSessionStarted(rejoined);

    await manager.onSessionEnded(old);

    expect(plugin.hasCaptureProcessor, isTrue,
        reason: 'plugin calls: ${plugin.calls}');
    expect(manager.isInCall, isTrue);

    await manager.onSessionEnded(rejoined);
    expect(plugin.hasCaptureProcessor, isFalse);
    expect(manager.isActive, isFalse);
  }, skip: voiceDspSkip);

  test('a library without the DSP is not taken for one, and says why', () {
    final other = NativeAudioProcessingManager(
        openLibrary: () => DynamicLibrary.process());
    expect(other.isSupported, isFalse);
    expect(other.unavailableReason, contains('incomplete'));
    other.dispose();

    final none = NativeAudioProcessingManager(openLibrary: () => null);
    expect(none.isSupported, isFalse);
    expect(none.unavailableReason, contains('missing'));
    none.dispose();
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
