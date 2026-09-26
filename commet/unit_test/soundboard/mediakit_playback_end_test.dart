// MediaKitSoundboardPlayer with its real media_kit instances, on mpv's null
// audio output, which plays in real time like a sound card. Needs libmpv
// (`libmpv.so`); without it the test skips, except in CI (the CI variable is
// set), where a silent skip would leave the soundboard's ending unguarded.
@TestOn('linux')
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:commet/client/components/soundboard/soundboard_emoji.dart';
import 'package:commet/client/components/soundboard/soundboard_sound.dart';
import 'package:commet/client/matrix/components/soundboard/mediakit_soundboard_player.dart';
import 'package:media_kit/media_kit.dart';
import 'package:test/test.dart';

const _toneMs = 1500;

/// A 440 Hz tone, 16-bit mono 48 kHz WAV.
Uint8List _toneWav(int ms) {
  const rate = 48000;
  final frames = rate * ms ~/ 1000;
  final data = ByteData(44 + frames * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + frames * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    final sample = 0.5 * math.sin(2 * math.pi * 440 * i / rate);
    data.setInt16(44 + i * 2, (sample * 32767).round(), Endian.little);
  }
  return data.buffer.asUint8List();
}

Object _libmpvSkip() {
  try {
    // ao=null, vo=null: no sound card or display needed.
    // ignore: invalid_use_of_visible_for_testing_member
    NativePlayer.test = true;
    MediaKit.ensureInitialized();
    return false;
  } catch (e) {
    final reason = 'libmpv not found ($e): install libmpv';
    if (Platform.environment['CI'] != null) throw StateError(reason);
    return reason;
  }
}

void main() {
  final skip = _libmpvSkip();

  test('a sound is released only after it has played to the end', () async {
    final dir = Directory.systemTemp.createTempSync('soundboard_end');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/tone.wav')
      ..writeAsBytesSync(_toneWav(_toneMs));

    final finished = Completer<int>();
    final clock = Stopwatch();
    final player = MediaKitSoundboardPlayer(
      resolveSound: (id) => SoundboardSound(
        soundId: id,
        name: id,
        emoji: const SoundboardEmoji.unicode('📯'),
        mediaUri: 'mxc://x/$id',
        mimeType: 'audio/wav',
        durationMs: _toneMs,
        normalizedGain: 1.0,
      ),
      resolvePlayableUri: (_) async => file.path,
      onInstanceFinished: (_) => finished.complete(clock.elapsedMilliseconds),
    );
    addTearDown(player.stopAll);

    clock.start();
    await player.start('e1', 'tone');
    final releasedAfterMs =
        await finished.future.timeout(const Duration(seconds: 10));

    // mpv reports the end of the file as soon as the last samples are queued
    // for the audio output, and releasing the instance then drops what is
    // still queued (about 0.4 s on the null output, 0.2 to 0.3 s on a real
    // one). Only an instance released after the tone has been heard in full
    // plays it to the end.
    expect(releasedAfterMs, greaterThanOrEqualTo(_toneMs));
  }, skip: skip);
}
