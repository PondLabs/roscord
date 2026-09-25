// Linux: the voice DSP inside the real WebRTC, end to end. Run by
// tools/voice_dsp/native_noise_loop.sh, which creates a PulseAudio
// microphone that plays the noisy speech fixture and measures what this
// test writes down.
//
// The microphone test ("Test microphone") is a call without a server: the
// microphone goes through WebRTC's audio device module, its audio
// processing module and our hook in librust_lib_commet, is encoded and
// sent over a local peer connection. WebRTC measures the energy of what
// each sender gets from the audio processing module (its `media-source`
// statistics), which is what is encoded, and of what the receiver decodes
// (`inbound-rtp`). Those are sampled every 100 ms while the fixture plays.
@TestOn('linux')
library;

import 'dart:io';

import 'package:commet/client/components/voip/audio_processing/audio_processing_manager.dart';
import 'package:commet/client/components/voip/audio_processing/audio_processing_manager_native.dart';
import 'package:commet/client/components/voip/webrtc_default_devices.dart';
import 'package:commet/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _mic = String.fromEnvironment('NS_LOOP_MIC');
const _micSink = String.fromEnvironment('NS_LOOP_MIC_SINK');
const _fixture = String.fromEnvironment('NS_LOOP_FIXTURE');
const _results = String.fromEnvironment('NS_LOOP_RESULTS');
const _captureOverrides = String.fromEnvironment('NS_LOOP_CAPTURE');
const _out = String.fromEnvironment('NS_LOOP_OUT');
const _monitor = bool.fromEnvironment('NS_LOOP_MONITOR');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the microphone test sends the voice without the room noise',
      (tester) async {
    expect(_fixture, isNotEmpty,
        reason: 'run tools/voice_dsp/native_noise_loop.sh');

    await tester.runAsync(() async {
      await preferences.init();
      // The shipping defaults, except what does not apply here: nothing
      // plays, so there is no far end to duck under nor a speaker to bleed.
      await preferences.voipNoiseSuppression.set(true);
      await preferences.voipInputSensitivityAuto.set(true);
      await preferences.voipFarEndDucking.set(false);
      await preferences.voipSpeakerBleed.set(false);
      await preferences.voipDefaultAudioInput.set(_mic);
      await preferences.voipDefaultAudioOutput.set(_out);

      // name=true|false,... on top of the microphone test's constraints.
      for (final pair
          in _captureOverrides.split(',').where((p) => p.isNotEmpty)) {
        final [name, value] = pair.split('=');
        // ignore: invalid_use_of_visible_for_testing_member
        NativeAudioProcessingManager.debugMicTestConstraints[name] =
            value == 'true';
      }

      final dsp =
          AudioProcessingManager.instance as NativeAudioProcessingManager;
      expect(dsp.isSupported, isTrue, reason: '${dsp.unavailableReason}');
      expect(await WebrtcDefaultDevices.selectOutputDevice(), isTrue,
          reason: 'no output device called $_out');
      expect(await dsp.startMicTest(), isTrue);
      await dsp.setMicTestMonitor(_monitor);

      final started = DateTime.now();
      int ms() => DateTime.now().difference(started).inMilliseconds;

      // What the DSP says it did: the first thing to read when this fails.
      final reports =
          StringBuffer('ms,level_db,vad,far_db,gain_db,rate,frames,flags\n');
      final reportSub = dsp.onReport.listen((r) => reports.writeln(
          '${ms()},${r.levelDb.toStringAsFixed(1)},${r.vad.toStringAsFixed(2)},'
          '${r.farLevelDb.toStringAsFixed(1)},${r.gainDb.toStringAsFixed(1)},'
          '${r.sampleRate},${r.frames},${r.flags}'));

      final stats = StringBuffer(
          'ms,sent_energy,sent_duration,received_energy,received_duration\n');
      var sampling = true;
      final sampler = () async {
        while (sampling) {
          final at = ms();
          double? sentE, sentD, recvE, recvD;
          // ignore: invalid_use_of_visible_for_testing_member
          for (final r in await dsp.debugMicTestStats()) {
            final v = r.values;
            if (r.type == 'media-source' && v['kind'] == 'audio') {
              sentE = (v['totalAudioEnergy'] as num?)?.toDouble();
              sentD = (v['totalSamplesDuration'] as num?)?.toDouble();
            } else if (r.type == 'inbound-rtp' && v['kind'] == 'audio') {
              recvE = (v['totalAudioEnergy'] as num?)?.toDouble();
              recvD = (v['totalSamplesDuration'] as num?)?.toDouble();
            }
          }
          stats.writeln('$at,$sentE,$sentD,$recvE,$recvD');
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }();

      await Future<void>.delayed(const Duration(milliseconds: 500));
      final playAt = ms();
      final play =
          await Process.run('paplay', ['--device=$_micSink', _fixture]);
      expect(play.exitCode, 0, reason: '${play.stderr}');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      sampling = false;
      await sampler;
      await reportSub.cancel();

      await File('$_results/stats.csv').writeAsString(stats.toString());
      await File('$_results/reports.csv').writeAsString(reports.toString());
      await File('$_results/play_ms.txt').writeAsString('$playAt\n');

      final report = dsp.lastReport;
      await File('$_results/report.txt').writeAsString(
          '${report?.sampleRate} ${report?.frames} ${report?.flags}\n');
      expect(report, isNotNull, reason: 'the DSP never reported');
      expect(report!.frames, greaterThan(500),
          reason: 'the hook in WebRTC got no microphone audio');
      expect(report.noiseSuppressionActive, isTrue);

      await dsp.stopMicTest();
    });
  });
}
