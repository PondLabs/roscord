// The web voice DSP is a LiveKit track processor (CommetWebTrackProcessor):
// the sender has to carry its processed track, never the raw microphone,
// for as long as the microphone is live. These drive the vendored LiveKit
// (third_party/livekit-client-sdk-flutter) through the operations a call
// performs on the microphone.
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeWebrtcChannel webrtc;

  setUp(() => (webrtc = FakeWebrtcChannel()).install());
  tearDown(() => webrtc.uninstall());

  Future<(lk.LocalAudioTrack, FakeSender, FakeAudioProcessor)> start() async {
    final processor = FakeAudioProcessor();
    final (track, sender) = await publishedMicrophone(lk.AudioCaptureOptions(
      noiseSuppression: false,
      processor: processor,
    ));
    return (track, sender, processor);
  }

  test('publishing sends the processed track', () async {
    final (track, sender, processor) = await start();
    expect(processor.running, isTrue);
    expect(sender.track, same(processor.processedTrack));
    expect(track.processor, same(processor));
  });

  // What the session does when the noise suppression preference flips, and
  // when the watchdog gives up on the DSP (MatrixLivekitVoipSession
  // _reapplyNoiseSuppression).
  test('restarting the microphone keeps the processor on the new capture',
      () async {
    final (track, sender, processor) = await start();

    await track
        .restartTrack(track.currentOptions.copyWith(noiseSuppression: true));

    expect(track.processor, same(processor),
        reason: 'the processor was dropped by the restart');
    expect(processor.running, isTrue);
    expect(processor.initInputs, ['mic-1', 'mic-2'],
        reason: 'the processor has to run on the new capture');
    expect(sender.track, same(processor.processedTrack),
        reason: 'the sender must carry the processed track');
    expect(webrtc.lastAudioConstraints()['noiseSuppression'], isTrue);
  });

  test('the raw microphone never reaches the sender during a restart',
      () async {
    final (track, sender, processor) = await start();
    sender.history.clear();

    await track.restartTrack();

    expect(sender.history.whereType<FakeProcessedTrack>(), isNotEmpty);
    expect(sender.history.where((t) => t != null && t is! FakeProcessedTrack),
        isEmpty,
        reason: 'unprocessed audio went out: ${sender.history}');
  });

  // LocalAudioTrack.setDeviceId, what Room.setAudioInputDevice does on web.
  test('switching microphones keeps the processor', () async {
    final (track, sender, processor) = await start();

    await track.setDeviceId('another-mic');

    expect(track.processor, same(processor));
    expect(sender.track, same(processor.processedTrack));
  });

  test('a processor that fails on restart leaves the new capture on the sender',
      () async {
    final (track, sender, processor) = await start();
    processor.failNextInit = true;

    await track.restartTrack();

    // Not the stopped capture: that would silence the user.
    expect(sender.track?.id, 'mic-2');
  });

  // setMicrophoneMute / setDeafened keep the capture open
  // (stopAudioCaptureOnMute: false, since 24f5669f).
  test('mute and unmute keep the processor', () async {
    final (track, sender, processor) = await start();

    await track.mute(stopOnMute: false);
    await track.unmute(stopOnMute: false);

    expect(track.processor, same(processor));
    expect(processor.initInputs, ['mic-1']);
    expect(sender.track, same(processor.processedTrack));
  });

  test('copyWith carries the processor and every capture option', () {
    final processor = FakeAudioProcessor();
    final options = lk.AudioCaptureOptions(
      deviceId: 'mic',
      noiseSuppression: false,
      echoCancellation: false,
      autoGainControl: false,
      highPassFilter: true,
      typingNoiseDetection: false,
      voiceIsolation: false,
      stopAudioCaptureOnMute: false,
      processor: processor,
    );
    final copy = options.copyWith(noiseSuppression: true);
    expect(copy.processor, same(processor));
    expect(copy.noiseSuppression, isTrue);
    expect(copy.deviceId, 'mic');
    expect(copy.echoCancellation, isFalse);
    expect(copy.autoGainControl, isFalse);
    expect(copy.highPassFilter, isTrue);
    expect(copy.typingNoiseDetection, isFalse);
    expect(copy.voiceIsolation, isFalse);
    expect(copy.stopAudioCaptureOnMute, isFalse);
  });
}
