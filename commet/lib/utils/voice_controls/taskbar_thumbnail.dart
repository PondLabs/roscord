import 'dart:async';
import 'dart:ui' as ui;

import 'package:commet/config/platform_utils.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Draws [glyph] in [color] on a transparent [size]×[size] square, as
/// straight-alpha RGBA.
typedef ThumbnailIconRenderer = Future<Uint8List> Function(
    IconData glyph, Color color, int size);

/// The call controls under roscord's taskbar thumbnail on Windows, as
/// Discord has them (issue #146). The runner does the Win32 side
/// (windows/runner/voice_thumb_bar.cpp): this decides what the buttons show,
/// draws their icons, and presses what is clicked.
class TaskbarThumbnail {
  TaskbarThumbnail({
    MethodChannel? channel,
    VoiceCallWatcher? watcher,
    ThumbnailIconRenderer? render,
  })  : _channel = channel ?? const MethodChannel(channelName),
        _watcher = watcher ?? VoiceCallWatcher.instance,
        _render = render ?? renderGlyph;

  static const channelName = "chat.commet.commetapp/taskbar";

  static final TaskbarThumbnail instance = TaskbarThumbnail();

  static bool get supported => PlatformUtils.isWindows;

  final MethodChannel _channel;
  final VoiceCallWatcher _watcher;
  final ThumbnailIconRenderer _render;

  TaskbarAppearance? _appearance;
  StreamSubscription? _changes;

  /// Bumped on every push, so a slow one does not land after a newer one.
  int _pushes = 0;

  Future<void> start() async {
    _channel.setMethodCallHandler(_onRunnerCall);
    _appearance = TaskbarAppearance.fromMap(
        await _channel.invokeMapMethod<String, Object?>("getAppearance"));
    _watcher.start();
    _changes = _watcher.changes.listen((_) => _pushLogged());
    await _push();
  }

  Future<void> stop() async {
    await _changes?.cancel();
    _changes = null;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _onRunnerCall(MethodCall call) async {
    switch (call.method) {
      case "onButtonClicked":
        final id = (call.arguments as Map)["id"] as int;
        if (id >= 0 && id < VoiceControl.values.length) {
          _watcher.press(VoiceControl.values[id]);
        }
      case "onAppearanceChanged":
        _appearance = TaskbarAppearance.fromMap(
            (call.arguments as Map).cast<String, Object?>());
        await _push();
    }
  }

  void _pushLogged() => _push().catchError((Object e, StackTrace s) {
        Log.onError(e, s, content: "Could not update the taskbar buttons");
      });

  Future<void> _push() async {
    final appearance = _appearance;
    if (appearance == null) return;
    final push = ++_pushes;

    final buttons = ThumbnailButton.of(_watcher.state, appearance);
    final sent = [
      for (final button in buttons)
        {
          "id": button.control.index,
          "hidden": button.hidden,
          "tooltip": button.tooltip,
          "icon": button.hidden
              ? null
              : await _render(button.glyph, button.color, appearance.iconSize),
          "size": appearance.iconSize,
        },
    ];

    if (push != _pushes) return;
    await _channel.invokeMethod("setButtons", sent);
  }
}

/// Draws a Material glyph the way [Icon] does, for a surface that is not a
/// Flutter view.
Future<Uint8List> renderGlyph(IconData glyph, Color color, int size) async {
  final recorder = ui.PictureRecorder();
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    text: TextSpan(
      text: String.fromCharCode(glyph.codePoint),
      style: TextStyle(
        fontFamily: glyph.fontFamily,
        package: glyph.fontPackage,
        fontSize: size.toDouble(),
        height: 1.0,
        color: color,
      ),
    ),
  )..layout();
  painter.paint(Canvas(recorder),
      Offset((size - painter.width) / 2, (size - painter.height) / 2));
  painter.dispose();

  final image = await recorder.endRecording().toImage(size, size);
  try {
    final bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// The taskbar as the runner reads it (windows/runner/voice_thumb_bar.cpp).
class TaskbarAppearance {
  const TaskbarAppearance({
    required this.light,
    required this.highContrast,
    required this.contrastText,
    required this.iconSize,
  });

  /// "Choose your Windows mode" (`SystemUsesLightTheme`), which the taskbar
  /// follows. Not the app mode, and not roscord's own theme.
  final bool light;

  /// A contrast theme is on.
  final bool highContrast;

  /// `COLOR_BTNTEXT` as 0xAARRGGBB: what a contrast theme draws interactive
  /// things in.
  final int contrastText;

  /// The icon size the taskbar asks for at this DPI, in pixels.
  final int iconSize;

  static TaskbarAppearance fromMap(Map<String, Object?>? map) =>
      TaskbarAppearance(
        light: map?["light"] as bool? ?? false,
        highContrast: map?["highContrast"] as bool? ?? false,
        contrastText: map?["contrastText"] as int? ?? 0xFFFFFFFF,
        iconSize: map?["iconSize"] as int? ?? 32,
      );
}

/// One button under the taskbar thumbnail.
class ThumbnailButton {
  const ThumbnailButton(
    this.control, {
    required this.hidden,
    required this.tooltip,
    required this.glyph,
    required this.color,
  });

  final VoiceControl control;
  final bool hidden;
  final String tooltip;

  /// The same glyphs as the call panel in the app.
  final IconData glyph;
  final Color color;

  /// The buttons for [state] on a taskbar that looks like [appearance].
  /// There are always the same three: Windows adds them once and can only
  /// hide them afterwards.
  static List<ThumbnailButton> of(
      VoiceCallState state, TaskbarAppearance appearance) {
    final shown = {
      for (final button in state.controls) button.control: button,
    };
    final palette = _Palette.of(appearance);
    return [
      for (final control in VoiceControl.values)
        switch (shown[control]) {
          null => ThumbnailButton(control,
              hidden: true,
              tooltip: "",
              glyph: _glyph(control, active: false),
              color: palette.text),
          final button => ThumbnailButton(control,
              hidden: false,
              tooltip: button.label,
              glyph: _glyph(control, active: button.active),
              color: button.active ? palette.active : palette.text),
        },
    ];
  }

  static IconData _glyph(VoiceControl control, {required bool active}) =>
      switch (control) {
        VoiceControl.mute => active ? Icons.mic_off_rounded : Icons.mic_rounded,
        VoiceControl.deafen =>
          active ? Icons.headset_off_rounded : Icons.headset_rounded,
        VoiceControl.disconnect => Icons.call_end_rounded,
      };
}

/// The colours the glyphs are drawn in: WinUI's `TextFillColorPrimary` and
/// `SystemFillColorCritical` for the taskbar's theme
/// (microsoft-ui-xaml, Common_themeresources_any.xaml).
class _Palette {
  const _Palette(this.text, this.active);

  final Color text;

  /// Muted or deafened: the slash says so too.
  final Color active;

  /// A contrast theme gets its own button text for everything: images are
  /// drawn in the colours it picked for text, never in one of ours.
  static _Palette of(TaskbarAppearance appearance) => appearance.highContrast
      ? _Palette(Color(appearance.contrastText), Color(appearance.contrastText))
      : appearance.light
          ? const _Palette(Color(0xE4000000), Color(0xFFC42B1C))
          : const _Palette(Color(0xFFFFFFFF), Color(0xFFFF99A4));
}
