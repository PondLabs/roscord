import 'package:commet/client/components/voip/audio_processing/audio_processing_manager.dart';
import 'package:commet/client/components/voip/audio_processing/microphone_noise_suppression.dart';
import 'package:commet/client/components/voip/webrtc_default_devices.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/main.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

/// The MediaDevices a legacy 1:1 call (matrix-dart-sdk) captures with.
///
/// The SDK asks for the microphone with fixed constraints
/// (UserMediaConstraints.micMediaConstraints: WebRTC's noise suppressor on,
/// no device), so the noise suppression preference never reached a 1:1
/// call: on desktop both suppressors ran, on the web ours never did, and
/// the picked microphone was not used. Every capture with audio gets what
/// any other microphone capture of the app asks for
/// (microphoneConstraints), and the stream goes through
/// [AudioProcessingManager.processMicrophoneStream]: on the web the voice
/// DSP's AudioWorklet, as for a voice room.
class NoiseSuppressedMediaDevices extends MediaDevices {
  final MediaDevices inner;
  final AudioProcessingManager Function() _dsp;
  final bool Function() _preference;
  final Future<String?> Function() _deviceId;

  NoiseSuppressedMediaDevices(
    this.inner, {
    AudioProcessingManager Function()? dsp,
    bool Function()? preference,
    Future<String?> Function()? deviceId,
  })  : _dsp = dsp ?? (() => AudioProcessingManager.instance),
        _preference =
            preference ?? (() => preferences.voipNoiseSuppression.value),
        _deviceId = deviceId ?? WebrtcDefaultDevices.getDefaultMicrophoneId;

  @override
  Future<MediaStream> getUserMedia(
      Map<String, dynamic> mediaConstraints) async {
    final audio = mediaConstraints['audio'];
    if (audio == null || audio == false) {
      return inner.getUserMedia(mediaConstraints);
    }

    final dsp = _dsp();
    await dsp.ensureReady();
    final deviceId = await _deviceId();
    Future<MediaStream> capture(bool webrtcSuppressor) => inner.getUserMedia({
          ...mediaConstraints,
          'audio': microphoneConstraints(
              webrtcNoiseSuppression: webrtcSuppressor, deviceId: deviceId),
        });

    final webrtcSuppressor = MicrophoneNoiseSuppression.webrtcSuppressorFor(dsp,
        preference: _preference());
    final stream = await capture(webrtcSuppressor);
    if (webrtcSuppressor) return stream;

    final processed = await dsp.processMicrophoneStream(stream);
    if (processed != null) return processed;
    // Ours could not start on this capture, which asked for WebRTC's to be
    // off: capture again with it on rather than send the noise.
    Log.w("Voice DSP: not running on this call, using WebRTC's noise "
        "suppression instead");
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
    return capture(true);
  }

  @override
  Future<MediaStream> getDisplayMedia(Map<String, dynamic> mediaConstraints) =>
      inner.getDisplayMedia(mediaConstraints);

  @override
  // ignore: deprecated_member_use
  Future<List<dynamic>> getSources() => inner.getSources();

  @override
  Future<List<MediaDeviceInfo>> enumerateDevices() => inner.enumerateDevices();

  @override
  MediaTrackSupportedConstraints getSupportedConstraints() =>
      inner.getSupportedConstraints();

  @override
  Function(dynamic event)? get ondevicechange => inner.ondevicechange;

  @override
  set ondevicechange(Function(dynamic event)? handler) =>
      inner.ondevicechange = handler;

  @override
  Future<MediaDeviceInfo> selectAudioOutput([AudioOutputOptions? options]) =>
      inner.selectAudioOutput(options);
}
