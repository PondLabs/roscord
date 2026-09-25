// The microphone and speakers the user picked, and getting WebRTC to
// actually use them.
//
// The pick is saved by name, because device ids are only meaningful while
// the device is plugged in. That leaves two ways to end up hearing nobody
// with the settings page still showing the right name:
//
// - the name was never found (the device came back under a slightly
//   different one, or was not ready when we looked), and the old code
//   returned without a word; or
// - nothing ever applied the pick, because it was only applied when a call
//   started and the result was neither awaited nor checked.
//
// So: [apply] is called at startup, before each call, and again whenever
// the device list changes; it says what it did; and what it could not do
// is remembered for the settings page to show.
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:commet/client/components/voip/audio_processing/audio_processing_manager.dart';
import 'package:commet/client/components/voip/audio_processing/microphone_noise_suppression.dart';
import 'package:commet/config/platform_utils.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/main.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

enum AudioDeviceKind { input, output }

class WebrtcDefaultDevices {
  /// The picked microphone for a legacy 1:1 call (desktop), captured like
  /// any other microphone (microphoneConstraints): the device the user
  /// picked, which `deviceId: {exact}` never selected on desktop, and
  /// WebRTC's own noise suppressor only when ours does not run.
  static Future<webrtc.MediaStream?> getDefaultMicrophone() async {
    if (PlatformUtils.isAndroid || PlatformUtils.isWeb) return null;

    await initDummyConnection();

    final picked = await _find(AudioDeviceKind.input);
    if (picked != null) {
      await _select(AudioDeviceKind.input, picked);
    }
    final dsp = AudioProcessingManager.instance;
    final constraints = microphoneConstraints(
      webrtcNoiseSuppression: MicrophoneNoiseSuppression.webrtcSuppressorFor(
          dsp,
          preference: preferences.voipNoiseSuppression.value),
      deviceId: picked?.deviceId,
    );

    return await webrtc.navigator.mediaDevices
        .getUserMedia({"audio": constraints});
  }

  static Future<List<webrtc.MediaDeviceInfo>> getDevices() async {
    await initDummyConnection();

    return webrtc.navigator.mediaDevices.enumerateDevices();
  }

  // See: https://github.com/flutter-webrtc/flutter-webrtc/issues/2018#issuecomment-4225654871
  static bool _hasCreatedDummyConnection = false;
  static Future<void> initDummyConnection() async {
    if (!_hasCreatedDummyConnection) {
      _hasCreatedDummyConnection = true;
      final _ = await webrtc.createPeerConnection(Map());
    }
  }

  static Future<String?> getDefaultMicrophoneId() async {
    if (PlatformUtils.isAndroid || PlatformUtils.isWeb) return null;
    return (await _find(AudioDeviceKind.input))?.deviceId;
  }

  /// Devices the user picked that are not here right now, so the settings
  /// page can say so instead of showing a name nothing is playing through.
  static final ValueNotifier<Set<AudioDeviceKind>> missing =
      ValueNotifier(const {});

  static String? _saved(AudioDeviceKind kind) => switch (kind) {
        AudioDeviceKind.input => preferences.voipDefaultAudioInput.value,
        AudioDeviceKind.output => preferences.voipDefaultAudioOutput.value,
      };

  static String _label(AudioDeviceKind kind) =>
      kind == AudioDeviceKind.input ? 'microphone' : 'speakers';

  /// The device the user picked, if it is here. Matched on the name, then
  /// on the id: a device that comes back after being unplugged keeps its
  /// name but can be given a new id, and the other way round when Windows
  /// renumbers it ("2- Headset" for "Headset").
  static Future<webrtc.MediaDeviceInfo?> _find(AudioDeviceKind kind) async {
    final wanted = _saved(kind);
    if (wanted == null) return null;
    final want = kind == AudioDeviceKind.input ? "audioinput" : "audiooutput";
    final devices = (await getDevices()).where((d) => d.kind == want);
    return devices.firstWhereOrNull((d) => d.label == wanted) ??
        devices.firstWhereOrNull((d) => d.deviceId == wanted);
  }

  static Future<bool> _select(
      AudioDeviceKind kind, webrtc.MediaDeviceInfo device) async {
    try {
      if (kind == AudioDeviceKind.input) {
        await webrtc.Helper.selectAudioInput(device.deviceId);
      } else {
        await webrtc.Helper.selectAudioOutput(device.deviceId);
      }
      Log.i("Voice: using ${_label(kind)} ${device.label} "
          "(${device.deviceId})");
      return true;
    } catch (e, s) {
      Log.onError(e, s,
          content: "Voice: could not use the picked ${_label(kind)}");
      return false;
    }
  }

  /// Hands WebRTC the device the user picked. Answers whether it is now in
  /// use: false means the pick is saved but nothing here matches it, which
  /// is worth telling the user rather than quietly using whatever the
  /// system would have chosen.
  static Future<bool> selectDevice(AudioDeviceKind kind) async {
    if (_saved(kind) == null) {
      _setMissing(kind, false);
      return true;
    }
    final device = await _find(kind);
    if (device == null) {
      Log.w("Voice: the picked ${_label(kind)} (${_saved(kind)}) is not here");
      _setMissing(kind, true);
      return false;
    }
    final ok = await _select(kind, device);
    _setMissing(kind, !ok);
    return ok;
  }

  static void _setMissing(AudioDeviceKind kind, bool value) {
    final next = {...missing.value};
    if (value ? !next.add(kind) : !next.remove(kind)) return;
    missing.value = next;
  }

  static Future<bool> selectInputDevice() =>
      selectDevice(AudioDeviceKind.input);

  static Future<bool> selectOutputDevice() =>
      selectDevice(AudioDeviceKind.output);

  /// Both devices, and from then on again whenever the list changes: a
  /// device plugged in after the app started, or one that came back, is
  /// picked up without the user going to settings.
  static Future<void> apply() async {
    if (PlatformUtils.isWeb) return;
    await selectOutputDevice();
    if (!PlatformUtils.isAndroid) await selectInputDevice();
    _watchDevices();
  }

  static bool _watching = false;
  static Timer? _settle;

  static void _watchDevices() {
    if (_watching) return;
    _watching = true;
    webrtc.navigator.mediaDevices.ondevicechange = (_) {
      // One change is usually several, and the list is not always up to
      // date the instant it fires.
      _settle?.cancel();
      _settle = Timer(const Duration(milliseconds: 500), () async {
        Log.i("Voice: the audio devices changed, applying the picked ones");
        await selectOutputDevice();
        if (!PlatformUtils.isAndroid) await selectInputDevice();
      });
    };
  }
}
