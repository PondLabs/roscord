// Desktop: screen-share audio and the DJ booth's music write their own
// processing options (echo cancellation, gain control and noise suppression
// off) onto the audio processing module WebRTC shares with the microphone.
// The microphone's are written back once the custom source is negotiated
// (shared_audio_processing.dart). What that does inside WebRTC is measured
// by integration_test/voice_dsp/native_noise_test.dart; these pin when it
// happens.
import 'package:commet/client/components/voip/audio_processing/shared_audio_processing.dart';
import 'package:commet/client/matrix/components/voip_room/livekit_microphone.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

/// A capture track that remembers every enabled it was given.
class _Capture implements rtc.MediaStreamTrack {
  final List<bool> sets = [];
  bool _enabled;
  _Capture({bool enabled = true}) : _enabled = enabled;

  @override
  bool get enabled => _enabled;

  @override
  set enabled(bool value) {
    _enabled = value;
    sets.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A sender that is negotiated after [pollsBefore] looks at its stats.
class _Sender implements rtc.RTCRtpSender {
  int pollsBefore;
  int polls = 0;
  _Sender(this.pollsBefore);

  @override
  Future<List<rtc.StatsReport>> getStats() async {
    polls++;
    return polls > pollsBefore
        ? [rtc.StatsReport('RTCOutboundRTPAudioStream', 'outbound-rtp', 0, {})]
        : [rtc.StatsReport('RTCMediaSourceStats', 'media-source', 0, {})];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Track implements lk.LocalAudioTrack {
  @override
  final rtc.MediaStreamTrack mediaStreamTrack;
  @override
  final rtc.RTCRtpSender? sender;
  _Track(this.mediaStreamTrack, [this.sender]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Publication implements lk.LocalTrackPublication<lk.LocalAudioTrack> {
  @override
  final lk.TrackSource source;
  @override
  final lk.TrackType kind;
  @override
  final lk.LocalAudioTrack? track;
  _Publication(this.source, this.track, {this.kind = lk.TrackType.AUDIO});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Participant implements lk.LocalParticipant {
  @override
  final List<lk.LocalTrackPublication<lk.LocalAudioTrack>>
      audioTrackPublications;
  _Participant(this.audioTrackPublications);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Capture mic;
  late _Participant participant;

  setUp(() {
    mic = _Capture();
    participant = _Participant(
        [_Publication(lk.TrackSource.microphone, _Track(mic, _Sender(0)))]);
  });

  _Publication custom(lk.TrackSource source, _Sender sender) =>
      _Publication(source, _Track(_Capture(), sender));

  Future<bool> restore(lk.LocalTrackPublication publication,
          {bool overridden = true,
          Duration timeout = const Duration(seconds: 5)}) =>
      restoreMicrophoneProcessingAfter(publication, participant,
          overridden: overridden,
          timeout: timeout,
          poll: const Duration(milliseconds: 1));

  test('after the screen audio is negotiated, the microphone writes its own',
      () async {
    final sender = _Sender(3);
    expect(
        await restore(custom(lk.TrackSource.screenShareAudio, sender)), isTrue);
    expect(sender.polls, 4, reason: 'restored before it was negotiated');
    expect(mic.sets, [false, true]);
    expect(mic.enabled, isTrue);
  });

  test('the DJ booth\'s music too', () async {
    expect(await restore(custom(lk.TrackSource.unknown, _Sender(0))), isTrue);
    expect(mic.sets, [false, true]);
  });

  test('the microphone itself and video leave it alone', () async {
    expect(await restore(participant.audioTrackPublications.single), isFalse);
    expect(
        await restore(_Publication(lk.TrackSource.screenShareVideo, null,
            kind: lk.TrackType.VIDEO)),
        isFalse);
    expect(mic.sets, isEmpty);
  });

  // Unmuting re-enables the track, and that writes its options back.
  test('a muted microphone is not turned on', () async {
    mic = _Capture(enabled: false);
    participant = _Participant(
        [_Publication(lk.TrackSource.microphone, _Track(mic, _Sender(0)))]);
    expect(await restore(custom(lk.TrackSource.unknown, _Sender(0))), isFalse);
    expect(mic.sets, isEmpty);
  });

  test('only where custom sources share the microphone\'s processing',
      () async {
    expect(
        await restore(custom(lk.TrackSource.unknown, _Sender(0)),
            overridden: false),
        isFalse);
    expect(restoreMicrophoneProcessing(mic, overridden: false), isFalse);
    expect(mic.sets, isEmpty);
  });

  test('a source that never gets negotiated still gets it restored', () async {
    expect(
        await restore(custom(lk.TrackSource.unknown, _Sender(1 << 30)),
            timeout: const Duration(milliseconds: 20)),
        isTrue);
    expect(mic.sets, [false, true]);
  });
}
