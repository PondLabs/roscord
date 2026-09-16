import 'dart:math' as math;

import 'package:commet/client/components/soundboard/soundboard_normalizer.dart';
import 'package:commet/client/matrix/components/soundboard/mediakit_soundboard_player.dart';
import 'package:test/test.dart';

// mpv's software volume multiplies samples by (volume / 100)^3.
double mpvAmplitude(double volume) => math.pow(volume / 100, 3).toDouble();

void main() {
  test('player volume is on media_kit\'s 0..100 scale', () {
    // 0.8 here once meant mpv volume 0.8 of 100: inaudible.
    expect(MediaKitSoundboardPlayer.mpvVolume(1.0, 1.0), closeTo(100, 1e-9));
    expect(MediaKitSoundboardPlayer.mpvVolume(0, 1.0), 0);
  });

  test('mpv plays the linear product of user volume and gain', () {
    for (final (user, gain) in [(0.8, 1.0), (1.0, 0.5), (0.5, 0.25)]) {
      expect(mpvAmplitude(MediaKitSoundboardPlayer.mpvVolume(user, gain)),
          closeTo(user * gain, 1e-9));
    }
  });

  test('a normalization boost is applied', () {
    expect(mpvAmplitude(MediaKitSoundboardPlayer.mpvVolume(1.0, 4.0)),
        closeTo(4.0, 1e-9));
  });

  test('the loudest allowed setting fits under mpv\'s volume-max', () {
    final loudest =
        MediaKitSoundboardPlayer.mpvVolume(1.5, SoundboardNormalizer.maxGain);
    expect(loudest, lessThanOrEqualTo(MediaKitSoundboardPlayer.mpvVolumeMax));
    expect(mpvAmplitude(loudest),
        closeTo(1.5 * SoundboardNormalizer.maxGain, 1e-9));
  });
}
