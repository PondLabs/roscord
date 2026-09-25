// The microphone of a LiveKit voice room: how it is created and found.
// Every microphone capture of a room goes through here, so who suppresses
// noise on it (MicrophoneNoiseSuppression) is decided in one place.
import 'package:collection/collection.dart';
import 'package:commet/client/components/voip/audio_processing/audio_processing_manager.dart';
import 'package:commet/client/components/voip/audio_processing/microphone_noise_suppression.dart';
import 'package:commet/client/components/voip/audio_processing/noise_suppression_notice.dart';
import 'package:commet/client/components/voip/audio_processing/shared_audio_processing.dart';
import 'package:commet/debug/log.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

/// Capture options for a room's microphone. WebRTC's (the browser's) own
/// noise suppressor only when ours will not run; on the web ours is the
/// track processor (native platforms hook into WebRTC's pipeline instead
/// and have none).
lk.AudioCaptureOptions microphoneCaptureOptions({
  required AudioProcessingManager dsp,
  required bool noiseSuppressionPreference,
  String? deviceId,
}) =>
    lk.AudioCaptureOptions(
      deviceId: deviceId,
      noiseSuppression: MicrophoneNoiseSuppression.webrtcSuppressorFor(dsp,
          preference: noiseSuppressionPreference),
      processor: dsp.createTrackProcessor(),
    );

/// A room microphone's capture options, once it is known whether our DSP
/// can run (on the web that means audio_dsp.wasm fetched and test-run). A
/// user who asked for noise suppression and cannot have ours is told.
Future<lk.AudioCaptureOptions> prepareMicrophoneCaptureOptions({
  required AudioProcessingManager dsp,
  required bool noiseSuppressionPreference,
  String? deviceId,
}) async {
  final ready = await dsp.ensureReady();
  final reason = dsp.unavailableReason;
  if (noiseSuppressionPreference && !ready && reason != null) {
    warnNoiseSuppressionUnavailable(reason);
  }
  return microphoneCaptureOptions(
    dsp: dsp,
    noiseSuppressionPreference: noiseSuppressionPreference,
    deviceId: deviceId,
  );
}

/// Options for `setMicrophoneEnabled` when the user mutes or unmutes.
///
/// A published microphone keeps what it captures with, told to keep
/// capturing while muted (`stopAudioCaptureOnMute` defaults to true): muting
/// otherwise closes the device, and on desktop that is a fresh getUserMedia,
/// a reset of WebRTC's shared audio processing and a teardown of the DSP
/// processor on every mute.
///
/// A microphone that was never published (the join could not: denied, or no
/// device yet) is created here by unmuting, so it gets a room microphone's
/// options, our DSP included. Left to LiveKit's defaults it went out without
/// the web DSP and with the suppressor chosen regardless of ours.
Future<lk.AudioCaptureOptions?> microphoneOptionsToToggle(
  lk.LocalParticipant? participant, {
  required bool enabling,
  required AudioProcessingManager dsp,
  required bool noiseSuppressionPreference,
  required Future<String?> Function() deviceId,
}) async {
  final track = microphonePublication(participant)?.track;
  if (track != null) {
    return track.currentOptions.copyWith(stopAudioCaptureOnMute: false);
  }
  // Muting what does not exist creates nothing, and a processor made for
  // nothing would replace the web DSP's current one.
  if (!enabling) return null;
  return (await prepareMicrophoneCaptureOptions(
    dsp: dsp,
    noiseSuppressionPreference: noiseSuppressionPreference,
    deviceId: await deviceId(),
  ))
      .copyWith(stopAudioCaptureOnMute: false);
}

/// The microphone's publication, found by its source. Not "the first audio
/// publication": that is the DJ booth's music or the screen share's audio
/// whenever those were published before the microphone was (it failed, or
/// was denied, at join), and restarting one of them with microphone
/// options replaces it with a microphone capture.
lk.LocalTrackPublication<lk.LocalAudioTrack>? microphonePublication(
        lk.LocalParticipant? participant) =>
    participant?.audioTrackPublications
        .firstWhereOrNull((p) => p.source == lk.TrackSource.microphone);

/// A room's microphone for [MicrophoneNoiseSuppression].
class LivekitMicrophone implements MicrophoneCapture {
  final lk.LocalTrackPublication<lk.LocalAudioTrack> publication;

  LivekitMicrophone(this.publication);

  static LivekitMicrophone? of(lk.LocalParticipant? participant) {
    final publication = microphonePublication(participant);
    return publication == null ? null : LivekitMicrophone(publication);
  }

  @override
  bool get live => publication.track != null && !publication.muted;

  @override
  bool get webrtcNoiseSuppression =>
      publication.track?.currentOptions.noiseSuppression ?? true;

  @override
  Future<void> restart({required bool webrtcNoiseSuppression}) async {
    final track = publication.track;
    if (track == null) return;
    await track.restartTrack(track.currentOptions
        .copyWith(noiseSuppression: webrtcNoiseSuppression));
  }
}

/// Desktop: once [custom] (screen-share audio, the DJ booth's music) has
/// written its options onto the audio processing module WebRTC shares with
/// the microphone, writes the microphone's back (see
/// shared_audio_processing.dart). A custom source writes them when its
/// sender is negotiated, which LiveKit does after announcing the
/// publication, so this waits for the sender to have outbound RTP
/// statistics, and restores anyway after [timeout].
Future<bool> restoreMicrophoneProcessingAfter(
  lk.LocalTrackPublication custom,
  lk.LocalParticipant participant, {
  bool? overridden,
  Duration timeout = const Duration(seconds: 10),
  Duration poll = const Duration(milliseconds: 100),
}) async {
  if (!(overridden ?? customAudioSourcesOverrideMicrophone)) return false;
  if (custom.kind != lk.TrackType.AUDIO ||
      custom.source == lk.TrackSource.microphone) {
    return false;
  }
  final sender = custom.track?.sender;
  if (sender != null) {
    final deadline = DateTime.now().add(timeout);
    while (!await _negotiated(sender)) {
      if (DateTime.now().isAfter(deadline)) {
        Log.w("Voice: a custom audio source was not negotiated in "
            "${timeout.inSeconds} s; restoring the microphone's processing "
            "anyway");
        break;
      }
      await Future<void>.delayed(poll);
    }
  }
  final track = microphonePublication(participant)?.track;
  if (track == null) return false;
  return restoreMicrophoneProcessing(track.mediaStreamTrack,
      overridden: overridden);
}

Future<bool> _negotiated(rtc.RTCRtpSender sender) async {
  try {
    return (await sender.getStats()).any((r) => r.type == 'outbound-rtp');
  } catch (_) {
    return false;
  }
}
