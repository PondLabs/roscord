// The vendored LiveKit plugin's audio processing host
// (third_party/livekit-client-sdk-flutter/shared_cpp/
// commet_external_audio_processing.h), in Dart: it answers the method
// channel the way livekit_plugin.cpp does and calls the callbacks it was
// given the way libwebrtc's APM calls the capture post-processing slot.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _InitNative = Void Function(Pointer<Void>, Int32, Int32);
typedef _Init = void Function(Pointer<Void>, int, int);
typedef _ProcessNative = Void Function(
    Pointer<Void>, Int32, Int32, Int32, Pointer<Float>);
typedef _Process = void Function(Pointer<Void>, int, int, int, Pointer<Float>);

class FakeLivekitPlugin {
  static const channel = MethodChannel('livekit_client');

  /// `set` and `clear`, in the order the plugin received them.
  final List<String> calls = [];

  int _ctx = 0;
  _Init? _init;
  _Process? _process;
  bool _initialized = false;
  int _rate = 0;

  bool get hasCaptureProcessor => _process != null;
  int get ctx => _ctx;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'commetSetExternalAudioProcessing':
          final args = (call.arguments as Map).cast<String, dynamic>();
          calls.add('set');
          final process = args['captureProcess'] as int;
          if (process == 0) {
            _clear();
            return true;
          }
          _ctx = args['ctx'] as int;
          _init = Pointer<NativeFunction<_InitNative>>.fromAddress(
                  args['captureInit'] as int)
              .asFunction<_Init>();
          _process =
              Pointer<NativeFunction<_ProcessNative>>.fromAddress(process)
                  .asFunction<_Process>();
          if (_initialized) _init!(Pointer.fromAddress(_ctx), _rate, 1);
          return true;
        case 'commetClearExternalAudioProcessing':
          calls.add('clear');
          _clear();
          return true;
      }
      return null;
    });
  }

  void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  void _clear() {
    _ctx = 0;
    _init = null;
    _process = null;
  }

  /// The APM starting (a microphone track exists).
  void initialize(int sampleRate) {
    _initialized = true;
    _rate = sampleRate;
    _init?.call(Pointer.fromAddress(_ctx), sampleRate, 1);
  }

  /// Runs [samples] (int16-scale floats at the initialized rate) through
  /// the capture slot in 10 ms blocks, in a buffer allocated by the DSP
  /// library itself ([alloc] / [free] are `commet_dsp_alloc_f32` /
  /// `commet_dsp_free_f32`). Blocks pass untouched while nothing is set.
  Float32List processCapture(
    Float32List samples, {
    required Pointer<Float> Function(int) alloc,
    required void Function(Pointer<Float>, int) free,
  }) {
    final n = _rate ~/ 100;
    final out = Float32List.fromList(samples);
    final buf = alloc(n);
    try {
      for (var start = 0; start + n <= out.length; start += n) {
        final process = _process;
        if (process == null) continue;
        final view = buf.asTypedList(n);
        view.setAll(0, out.sublist(start, start + n));
        process(Pointer.fromAddress(_ctx), 3, n, n, buf);
        out.setAll(start, view);
      }
    } finally {
      free(buf, n);
    }
    return out;
  }
}
