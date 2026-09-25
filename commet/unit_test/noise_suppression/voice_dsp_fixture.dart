// The voice DSP's native library and the "speech in a noisy room" fixture,
// for the tests that put real audio through it.
//
// Both are built with cargo when missing: `cargo build -p audio_dsp`
// (target/debug/libaudio_dsp.so) and
// `cargo run -p audio_dsp --example noisy_speech -- target/voice-fixtures`.
// Without cargo the tests skip, except in CI (the CI variable is set), where a
// test that silently skipped would leave noise suppression unguarded.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const repoRoot = '..';
const dspLibraryPath = '$repoRoot/target/debug/libaudio_dsp.so';
const fixtureDir = '$repoRoot/target/voice-fixtures';

/// 10 ms at 48 kHz.
const blockSize = 480;

/// What the fixture-driven tests ask of noise suppression.
const minNoiseDropDb = 20.0;
const maxSpeechLossDb = 4.0;

/// False when the library and the fixture are there (or could be built),
/// otherwise the reason to skip.
final Object voiceDspSkip = _prepare();

Object _prepare() {
  final missing = <String>[];
  if (!File(dspLibraryPath).existsSync()) {
    if (!_cargo(['build', '-p', 'audio_dsp'])) missing.add(dspLibraryPath);
  }
  if (!File('$fixtureDir/noisy_speech_48k.wav').existsSync()) {
    if (!_cargo([
      'run',
      '-q',
      '-p',
      'audio_dsp',
      '--release',
      '--example',
      'noisy_speech',
      '--',
      'target/voice-fixtures'
    ])) {
      missing.add('$fixtureDir/noisy_speech_48k.wav');
    }
  }
  if (missing.isEmpty) return false;
  final reason = 'missing ${missing.join(', ')}: run '
      '`cargo build -p audio_dsp` and '
      '`cargo run -p audio_dsp --example noisy_speech -- target/voice-fixtures`';
  if (Platform.environment['CI'] != null) throw StateError(reason);
  return reason;
}

bool _cargo(List<String> args) {
  try {
    return Process.runSync('cargo', args, workingDirectory: repoRoot)
            .exitCode ==
        0;
  } on ProcessException {
    return false;
  }
}

class NoisySpeech {
  /// Mono, 48 kHz, int16-scale floats (what WebRTC's APM hands its hooks).
  final Float32List samples;

  /// One character per 10 ms block: `s` speech, `n` noise only, `.` skip.
  final String labels;

  NoisySpeech(this.samples, this.labels);

  static NoisySpeech load() {
    final bytes = File('$fixtureDir/noisy_speech_48k.wav').readAsBytesSync();
    final labels =
        File('$fixtureDir/noisy_speech_48k.labels').readAsStringSync().trim();
    return NoisySpeech(_pcm16(bytes), labels);
  }

  static Float32List _pcm16(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var pos = 12;
    while (pos + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes, pos, pos + 4);
      final len = data.getUint32(pos + 4, Endian.little);
      if (id == 'data') {
        final out = Float32List(len ~/ 2);
        for (var i = 0; i < out.length; i++) {
          out[i] = data.getInt16(pos + 8 + 2 * i, Endian.little).toDouble();
        }
        return out;
      }
      pos += 8 + len + (len & 1);
    }
    throw const FormatException('no data chunk');
  }
}

class NoiseMeasurement {
  /// How much quieter the noise-only stretches came out, dB.
  final double noiseDropDb;

  /// How the speech stretches changed, dB (negative: quieter).
  final double speechChangeDb;

  NoiseMeasurement(this.noiseDropDb, this.speechChangeDb);

  @override
  String toString() => 'noise ${noiseDropDb.toStringAsFixed(1)} dB down, '
      'speech ${speechChangeDb.toStringAsFixed(1)} dB';
}

/// Compares [output] with [input] block by block over the fixture's labels.
/// The first half second of noise is left out: RNNoise and the gate settle.
NoiseMeasurement measure(Float32List input, Float32List output, String labels,
    {int fromBlock = 0}) {
  double ms(Float32List x, int block) {
    var acc = 0.0;
    for (var i = block * blockSize; i < (block + 1) * blockSize; i++) {
      acc += x[i] * x[i];
    }
    return acc / blockSize;
  }

  var inN = 0.0, outN = 0.0, inS = 0.0, outS = 0.0;
  final blocks = math.min(labels.length, input.length ~/ blockSize);
  for (var b = math.max(fromBlock, 0); b < blocks; b++) {
    final label = labels[b];
    if (label == 'n' && b >= fromBlock + 50) {
      inN += ms(input, b);
      outN += ms(output, b);
    } else if (label == 's') {
      inS += ms(input, b);
      outS += ms(output, b);
    }
  }
  double db(double x) => 10 * math.log(math.max(x, 1e-12)) / math.ln10;
  return NoiseMeasurement(db(inN) - db(outN), db(outS) - db(inS));
}
