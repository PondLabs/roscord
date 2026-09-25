import 'dart:async';

import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/config/build_config.dart';
import 'package:commet/config/platform_utils.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:commet/utils/window_management.dart';
import 'package:intl/intl.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

enum VoiceTrayStatus {
  /// Not in a call: the app logo.
  idle,

  /// In a call and heard: a mic.
  live,

  /// In a call, muted or deafened: a crossed-out mic.
  muted,
}

/// The system tray icon, like Discord's: the app logo, or while we are in a
/// voice call a mic showing whether we can be heard. Clicking it (Windows) or
/// its "Open" item (Linux, where a click always opens the menu) brings the
/// window back. In a call its menu has the same controls as the taskbar
/// thumbnail (see voice_controls/).
///
/// Windows and Linux only. On Linux it needs an appindicator; a build without
/// one runs with no tray icon (see third_party/tray_manager).
class VoiceTray with TrayListener {
  VoiceTray._();

  static final VoiceTray instance = VoiceTray._();

  static String labelTrayOpen(String app) => Intl.message("Open $app",
      name: "labelTrayOpen",
      args: [app],
      desc: "Tray icon menu item that brings the app window back");

  static String get labelTrayQuit => Intl.message("Quit",
      name: "labelTrayQuit", desc: "Tray icon menu item that closes the app");

  static String get tooltipTrayInCall => Intl.message("In a voice channel",
      name: "tooltipTrayInCall",
      desc: "Tray icon tooltip while in a call and not muted");

  static String get tooltipTrayMuted => Intl.message("Muted",
      name: "tooltipTrayMuted",
      desc: "Tray icon tooltip while in a call and muted or deafened");

  static const _open = "open";
  static const _quit = "quit";

  static bool get supported => PlatformUtils.isWindows || PlatformUtils.isLinux;

  /// What the icon shows for [sessions]: muted only when every call we are
  /// in has us muted or deafened.
  static VoiceTrayStatus statusOf(Iterable<VoipSession> sessions) =>
      _statusFor(VoiceCallState.of(sessions));

  static VoiceTrayStatus _statusFor(VoiceCallState state) => !state.inCall
      ? VoiceTrayStatus.idle
      : state.muted
          ? VoiceTrayStatus.muted
          : VoiceTrayStatus.live;

  /// The menu for [state]: the call controls while in a call, between
  /// opening the window and quitting.
  static Menu menuOf(VoiceCallState state) => Menu(items: [
        MenuItem(key: _open, label: labelTrayOpen(BuildConfig.app)),
        if (state.inCall) ...[
          MenuItem.separator(),
          for (final button in state.controls)
            MenuItem(key: button.control.name, label: button.label),
        ],
        MenuItem.separator(),
        MenuItem(key: _quit, label: labelTrayQuit),
      ]);

  bool _started = false;
  bool _available = false;
  StreamSubscription? _changes;

  Future<void> init() async {
    if (!supported || _started) return;
    _started = true;

    trayManager.addListener(this);
    try {
      await _show(VoiceCallState.idle);
    } catch (e) {
      // Linux without an appindicator: no tray, nothing else changes.
      Log.w("No system tray icon: $e");
      trayManager.removeListener(this);
      return;
    }
    _available = true;

    final calls = VoiceCallWatcher.instance..start();
    _changes = calls.changes.listen(_update);
    _update(calls.state);
  }

  /// Takes the icon down, so Windows doesn't leave a dead one behind.
  Future<void> dispose() async {
    if (!_available) return;
    _available = false;
    _changes?.cancel();
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (e) {
      Log.w("Could not remove the tray icon: $e");
    }
  }

  void _update(VoiceCallState state) {
    if (!_available) return;
    _show(state).catchError((Object e, StackTrace s) {
      Log.onError(e, s, content: "Could not update the tray icon");
    });
  }

  Future<void> _show(VoiceCallState state) async {
    final status = _statusFor(state);

    // Windows loads tray icons from .ico, the appindicator from an image.
    final extension = PlatformUtils.isWindows ? "ico" : "png";
    await trayManager.setIcon("assets/images/tray/${status.name}.$extension");
    await trayManager.setContextMenu(menuOf(state));

    try {
      await trayManager.setToolTip(switch (status) {
        VoiceTrayStatus.idle => BuildConfig.app,
        VoiceTrayStatus.live => "${BuildConfig.app}: $tooltipTrayInCall",
        VoiceTrayStatus.muted => "${BuildConfig.app}: $tooltipTrayMuted",
      });
    } catch (_) {
      // Appindicators have no tooltips.
    }
  }

  Future<void> _openWindow() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } catch (e, s) {
      Log.onError(e, s, content: "Could not bring the window back");
    }
  }

  // Windows only: on Linux a click opens the menu.
  @override
  void onTrayIconMouseDown() => _openWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _open:
        _openWindow();
      case _quit:
        WindowManagement.close();
      case final key?:
        VoiceCallWatcher.instance.pressNamed(key);
    }
  }
}
