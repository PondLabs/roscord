// Browser SoundboardPlayer on Web Audio: each sound is decoded once into an
// AudioBuffer and played through its own AudioBufferSourceNode -> GainNode,
// so the gain can exceed 1.0 (normalization boosts) unlike <audio>.volume.
// Same semantics as MediaKitSoundboardPlayer: polyphonic across sounds,
// restart per soundId, errors logged and swallowed.
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:commet/client/components/soundboard/soundboard_normalizer.dart';
import 'package:commet/client/matrix/components/soundboard/soundboard_player_factory.dart';
import 'package:commet/debug/log.dart';
import 'package:web/web.dart' as web;

class _Voice {
  final web.AudioBufferSourceNode source;
  final web.GainNode gain;
  _Voice(this.source, this.gain);
}

class WebAudioSoundboardPlayer implements PreloadingSoundboardPlayer {
  final SoundResolver resolveSound;
  final BytesLoader loadBytes;

  web.AudioContext? _context;
  final Map<String, Future<web.AudioBuffer>> _buffers = {};
  final Map<String, _Voice> _voices = {};
  final Map<String, double> _normalizedGain = {};
  double _userVolume = 0.8;

  WebAudioSoundboardPlayer({
    required this.resolveSound,
    required this.loadBytes,
  });

  web.AudioContext get _ctx => _context ??= web.AudioContext();

  double _amplitude(String soundId) =>
      (_userVolume * (_normalizedGain[soundId] ?? 1.0))
          .clamp(0.0, 1.5 * SoundboardNormalizer.maxGain);

  Future<web.AudioBuffer> _buffer(String soundId) {
    final cached = _buffers[soundId];
    if (cached != null) return cached;
    final sound = resolveSound(soundId);
    if (sound == null) {
      return Future.error(StateError('Unknown sound $soundId'));
    }
    final future = () async {
      final bytes = await loadBytes(sound);
      // decodeAudioData detaches the buffer it gets; hand it a copy.
      final copy = Uint8List.fromList(bytes).buffer.toJS;
      return _ctx.decodeAudioData(copy).toDart;
    }();
    _buffers[soundId] = future;
    // A failed load is retried on the next play.
    future.then<void>((_) {}, onError: (Object _) {
      _buffers.remove(soundId);
    });
    return future;
  }

  @override
  Future<void> preload(String soundId) => _buffer(soundId);

  @override
  Future<void> start(String soundId) async {
    try {
      // Autoplay policy: a click is a user gesture, so resume works here.
      if (_ctx.state == 'suspended') await _ctx.resume().toDart;
      final buffer = await _buffer(soundId);
      // After the await: a second click during the load must still replace
      // the first voice, not layer on it.
      _stopVoice(soundId);
      final sound = resolveSound(soundId);
      if (sound != null) _normalizedGain[soundId] = sound.normalizedGain;
      final gain = _ctx.createGain()..gain.value = _amplitude(soundId);
      final source = _ctx.createBufferSource()..buffer = buffer;
      source.connect(gain);
      gain.connect(_ctx.destination);
      final voice = _Voice(source, gain);
      source.onended = ((web.Event _) {
        if (identical(_voices[soundId], voice)) _voices.remove(soundId);
        gain.disconnect();
      }).toJS;
      _voices[soundId] = voice;
      source.start();
    } catch (e, s) {
      Log.onError(e, s, content: 'Soundboard play failed: $soundId');
      _voices.remove(soundId);
    }
  }

  void _stopVoice(String soundId) {
    final voice = _voices.remove(soundId);
    if (voice == null) return;
    try {
      voice.source.stop();
      voice.gain.disconnect();
    } catch (_) {}
  }

  @override
  Future<void> stop(String soundId) async => _stopVoice(soundId);

  @override
  Future<void> stopAll() async {
    for (final id in _voices.keys.toList()) {
      _stopVoice(id);
    }
  }

  @override
  Future<void> setVolumeFor(String soundId, double volume) async {
    _userVolume = volume.clamp(0.0, 1.5);
    _voices[soundId]?.gain.gain.value = _amplitude(soundId);
  }

  @override
  bool isPlaying(String soundId) => _voices.containsKey(soundId);
}
