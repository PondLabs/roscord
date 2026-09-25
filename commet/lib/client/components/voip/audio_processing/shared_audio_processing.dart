// Desktop WebRTC runs one audio processing module (APM) for the whole
// process: WebRTC's echo canceller, gain control and noise suppressor, for
// every microphone capture. Each audio sender writes its source's options
// into it when it starts sending (WebRtcVoiceSendChannel::SetAudioSend →
// SetOptions → ApplyAudioProcessingOptions, in libwebrtc), and the last one
// to write wins. Removing a sender writes nothing back.
//
// Screen-share system audio and the DJ booth's music are custom sources,
// created with echo cancellation, gain control and noise suppression off
// (right for them: they do not go through the APM). Publishing one used to
// switch those off for the microphone until it was muted and unmuted: echo
// for everyone listening to someone on loudspeakers, and no noise
// suppression where WebRTC's is the one meant to run.
//
// restoreMicrophoneProcessing writes the microphone's options back after a
// custom source has written its own, by turning the microphone's capture
// track off and on: re-enabling a track makes its sender apply its options
// again. That is a libwebrtc internal, not an API. If an update changes it,
// integration_test/voice_dsp/native_noise_test.dart ("a custom audio source
// leaves the microphone's processing alone") fails; see
// docs/voice-audio-processing.md, "Known gaps".
import 'package:commet/config/platform_utils.dart';
import 'package:commet/debug/log.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Whether this platform's WebRTC shares one audio processing module that
/// custom audio sources overwrite (the vendored flutter-webrtc's C++ on
/// Linux and Windows). The browser processes each track on its own.
bool get customAudioSourcesOverrideMicrophone =>
    PlatformUtils.isLinux || PlatformUtils.isWindows;

/// Puts [microphone]'s processing options back on the shared audio
/// processing module, after a custom audio source wrote its own there. A
/// disabled (muted) microphone is left as it is: enabling it writes them.
/// Returns whether it did anything.
bool restoreMicrophoneProcessing(rtc.MediaStreamTrack microphone,
    {bool? overridden}) {
  if (!(overridden ?? customAudioSourcesOverrideMicrophone)) return false;
  if (!microphone.enabled) return false;
  // Two platform calls, handled in order. The microphone is disabled for
  // the time between them, about one 10 ms block.
  microphone.enabled = false;
  microphone.enabled = true;
  Log.i("Voice: put the microphone's echo cancellation, gain control and "
      "noise suppression back after a custom audio source");
  return true;
}
