// The buttons under roscord's taskbar thumbnail on Windows (issue #146).
import 'dart:async';

import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client_manager.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/utils/voice_controls/taskbar_thumbnail.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Session implements VoipSession {
  @override
  VoipState state = VoipState.connected;
  @override
  bool isMicrophoneMuted = false;
  @override
  bool isDeafened = false;

  final _changed = StreamController<void>.broadcast();
  @override
  Stream<void> get onStateChanged => _changed.stream;

  @override
  Future<void> setMicrophoneMute(bool state) async {
    isMicrophoneMuted = state;
    _changed.add(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The runner's side of the channel: answers with [appearance] and keeps
/// what it is sent.
class _Runner {
  _Runner(this.channel) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case "getAppearance":
          return appearance;
        case "setButtons":
          sent.add((call.arguments as List).cast<Map>());
      }
      return null;
    });
  }

  final MethodChannel channel;
  Map<String, Object> appearance = {
    "light": false,
    "highContrast": false,
    "contrastText": 0,
    "iconSize": 32,
  };
  final List<List<Map>> sent = [];

  /// What a button came to look like last: (hidden, tooltip, icon size).
  List<(bool, String, int?)> get last => sent.last
      .map((b) => (
            b["hidden"] as bool,
            b["tooltip"] as String,
            (b["icon"] as Uint8List?)?.length,
          ))
      .toList();

  Future<void> tell(String method, [Object? arguments]) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
              channel.name,
              channel.codec.encodeMethodCall(MethodCall(method, arguments)),
              (_) {});
}

/// Draws nothing, but at the size and in the colour asked.
final List<(IconData, Color, int)> _rendered = [];
Future<Uint8List> _render(IconData glyph, Color color, int size) async {
  _rendered.add((glyph, color, size));
  return Uint8List(size * size * 4);
}

const _darkTaskbar = TaskbarAppearance(
    light: false, highContrast: false, contrastText: 0, iconSize: 32);

const _lightTaskbar = TaskbarAppearance(
    light: true, highContrast: false, contrastText: 0, iconSize: 32);

const _heard = VoiceCallState(inCall: true, muted: false, deafened: false);

/// What each button draws: its tooltip, glyph and colour.
List<(String, IconData, Color)> _drawn(
        VoiceCallState state, TaskbarAppearance appearance) =>
    ThumbnailButton.of(state, appearance)
        .map((b) => (b.tooltip, b.glyph, b.color))
        .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group("Talking to the runner", _channelTests);

  group("Thumbnail buttons", () {
    test("all three hidden outside a call: Windows cannot remove them", () {
      final buttons = ThumbnailButton.of(VoiceCallState.idle, _darkTaskbar);
      expect(buttons.map((b) => (b.control, b.hidden)), [
        (VoiceControl.mute, true),
        (VoiceControl.deafen, true),
        (VoiceControl.disconnect, true),
      ]);
    });

    test("in a call, the call panel's glyphs in white on a dark taskbar", () {
      // White is WinUI's TextFillColorPrimary in the dark theme.
      expect(ThumbnailButton.of(_heard, _darkTaskbar).map((b) => b.hidden),
          everyElement(isFalse));
      expect(_drawn(_heard, _darkTaskbar), [
        ("Mute", Icons.mic_rounded, const Color(0xFFFFFFFF)),
        ("Deafen", Icons.headset_rounded, const Color(0xFFFFFFFF)),
        ("Disconnect", Icons.call_end_rounded, const Color(0xFFFFFFFF)),
      ]);
    });

    test("slashed glyphs in the critical colour while deafened", () {
      // #FF99A4 is WinUI's SystemFillColorCritical in the dark theme. The
      // slash tells the state by shape as well; disconnect has no state.
      const deafened =
          VoiceCallState(inCall: true, muted: true, deafened: true);
      expect(_drawn(deafened, _darkTaskbar), [
        ("Unmute", Icons.mic_off_rounded, const Color(0xFFFF99A4)),
        ("Undeafen", Icons.headset_off_rounded, const Color(0xFFFF99A4)),
        ("Disconnect", Icons.call_end_rounded, const Color(0xFFFFFFFF)),
      ]);
    });

    test("the light theme's colours on a light taskbar", () {
      // WinUI's light TextFillColorPrimary and SystemFillColorCritical.
      const muted = VoiceCallState(inCall: true, muted: true, deafened: false);
      expect(_drawn(muted, _lightTaskbar).map((d) => d.$3), [
        const Color(0xFFC42B1C),
        const Color(0xE4000000),
        const Color(0xE4000000),
      ]);
    });

    test("a contrast theme's button text for every glyph, and no red", () {
      // Win32 high contrast guidance: draw images in the text colours the
      // theme picked. The slash alone tells muted from not.
      const contrast = TaskbarAppearance(
          light: false,
          highContrast: true,
          contrastText: 0xFFFFFF00,
          iconSize: 32);
      const muted = VoiceCallState(inCall: true, muted: true, deafened: false);
      expect(_drawn(muted, contrast).map((d) => (d.$2, d.$3)), [
        (Icons.mic_off_rounded, const Color(0xFFFFFF00)),
        (Icons.headset_rounded, const Color(0xFFFFFF00)),
        (Icons.call_end_rounded, const Color(0xFFFFFF00)),
      ]);
    });
  });
}

void _channelTests() {
  late CallManager calls;
  late VoiceCallWatcher watcher;
  late _Runner runner;
  late TaskbarThumbnail thumbnail;

  setUp(() async {
    _rendered.clear();
    calls = CallManager(ClientManager());
    watcher = VoiceCallWatcher(() => calls)..start(poll: null);
    runner = _Runner(const MethodChannel("test/taskbar"));
    thumbnail = TaskbarThumbnail(
        channel: runner.channel, watcher: watcher, render: _render);
  });

  tearDown(() async {
    await thumbnail.stop();
    watcher.stop();
  });

  test("sends the buttons as the call stands, hidden outside one", () async {
    await thumbnail.start();
    expect(runner.last, [(true, "", null), (true, "", null), (true, "", null)]);
  });

  test("shows them, with icons at the taskbar's size, once in a call",
      () async {
    await thumbnail.start();
    calls.currentSessions.add(_Session());
    await pumpEventQueue();
    expect(runner.last, [
      (false, "Mute", 32 * 32 * 4),
      (false, "Deafen", 32 * 32 * 4),
      (false, "Disconnect", 32 * 32 * 4),
    ]);
  });

  test("redraws them when Windows mode, contrast or DPI changes", () async {
    calls.currentSessions.add(_Session());
    await thumbnail.start();
    await pumpEventQueue();
    _rendered.clear();

    await runner.tell("onAppearanceChanged", {
      "light": true,
      "highContrast": false,
      "contrastText": 0,
      "iconSize": 48,
    });
    await pumpEventQueue();
    expect(_rendered, [
      (Icons.mic_rounded, const Color(0xE4000000), 48),
      (Icons.headset_rounded, const Color(0xE4000000), 48),
      (Icons.call_end_rounded, const Color(0xE4000000), 48),
    ]);
    expect(runner.last.map((b) => b.$3), everyElement(48 * 48 * 4));
  });

  test("a click on a button presses its control", () async {
    final session = _Session();
    calls.currentSessions.add(session);
    await thumbnail.start();
    await pumpEventQueue();

    await runner.tell("onButtonClicked", {"id": VoiceControl.mute.index});
    await pumpEventQueue();
    expect(session.isMicrophoneMuted, isTrue);
    expect(runner.last.first.$2, "Unmute");
  });
}
