// A voice room's microphone in the browser, made the way a call makes it
// (prepareMicrophoneCaptureOptions, then LiveKit's LocalAudioTrack with our
// AudioWorklet as its processor) and put on a real RTCRtpSender, as
// publishing does. What that sender carries is what is encoded and sent.
//
// Built by tools/voice_dsp/web_noise_loop.mjs --app, which plays a noisy
// fixture as Chrome's microphone and records window.__voiceLoop.sent. See
// docs/voice-audio-processing.md.
//
//   flutter build web -t integration_test/voice_dsp/web_noise_main.dart \
//     --dart-define PLATFORM=web -o build/web_noise_loop
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:commet/client/components/voip/audio_processing/audio_processing_manager.dart';
import 'package:commet/client/matrix/components/voip_room/livekit_microphone.dart';
import 'package:commet/main.dart' show preferences;
// ignore: depend_on_referenced_packages
import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamTrackWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());

  final loop = JSObject();
  globalContext['__voiceLoop'] = loop;
  try {
    await preferences.init();
    final dsp = AudioProcessingManager.instance;
    final options = await prepareMicrophoneCaptureOptions(
        dsp: dsp, noiseSuppressionPreference: true);
    loop['dspReady'] = dsp.isSupported.toJS;
    loop['unavailableReason'] = dsp.unavailableReason?.toJS;
    loop['browserSuppressor'] = options.noiseSuppression.toJS;

    final track = await lk.LocalAudioTrack.create(options);
    final pc = await rtc.createPeerConnection({});
    track.transceiver = await pc.addTransceiver(
      track: track.mediaStreamTrack,
      kind: rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: rtc.RTCRtpTransceiverInit(
          direction: rtc.TransceiverDirection.SendOnly),
    );
    await track.start();

    // The browser moves the sender to a replaced track once the replace
    // has run, which LiveKit does not wait for; the harness reads this again
    // a moment after a restart.
    void expose() {
      final sent = _js(track.sender?.track);
      loop['sent'] = sent;
      // ignore: invalid_use_of_internal_member
      loop['raw'] = _js(track.originalTrack ?? track.mediaStreamTrack);
      loop['processor'] = (track.processor?.processedTrack != null).toJS;
      loop['sendingProcessed'] = (sent != null &&
              _js(track.processor?.processedTrack)?.getProperty('id'.toJS) ==
                  sent.getProperty('id'.toJS))
          .toJS;
    }

    Future<JSAny?> restart() async {
      // What a microphone switch or the noise suppression preference
      // flipping mid-call does.
      await track
          .restartTrack(track.currentOptions.copyWith(noiseSuppression: false));
      expose();
      return null;
    }

    expose();
    loop['restart'] = (() => restart().toJS).toJS;
    loop['refresh'] = expose.toJS;
    loop['state'] = 'published'.toJS;
  } catch (e, s) {
    loop['error'] = '$e\n$s'.toJS;
    loop['state'] = 'failed'.toJS;
  }
}

JSObject? _js(rtc.MediaStreamTrack? track) =>
    track is MediaStreamTrackWeb ? track.jsTrack : null;
