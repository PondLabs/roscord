import 'dart:async';

import 'package:commet/config/platform_utils.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:flutter/services.dart';

/// The call controls in roscord's Dock menu on macOS, the nearest thing it
/// has to Windows' thumbnail buttons (issue #146). The Dock asks for its
/// menu each time it opens it; the runner builds it from the items sent
/// here (macos/Runner/AppDelegate.swift).
///
/// Labels change with the call (Mute / Unmute), as Apple's guidelines
/// suggest for toggles, rather than showing icons or checkmarks: a Dock menu
/// does not reliably draw either.
class DockMenu {
  DockMenu({MethodChannel? channel, VoiceCallWatcher? watcher})
      : _channel = channel ?? const MethodChannel(channelName),
        _watcher = watcher ?? VoiceCallWatcher.instance;

  static const channelName = "chat.commet.commetapp/dock";

  static final DockMenu instance = DockMenu();

  static bool get supported => PlatformUtils.isMacOS;

  final MethodChannel _channel;
  final VoiceCallWatcher _watcher;
  StreamSubscription? _changes;

  Future<void> start() async {
    _channel.setMethodCallHandler(_onRunnerCall);
    _watcher.start();
    _changes = _watcher.changes.listen((_) => _sendLogged());
    await _send();
  }

  Future<void> stop() async {
    await _changes?.cancel();
    _changes = null;
    _channel.setMethodCallHandler(null);
  }

  Future<void> _onRunnerCall(MethodCall call) async {
    if (call.method != "onItemClicked") return;
    final id = (call.arguments as Map)["id"] as int;
    if (id >= 0 && id < VoiceControl.values.length) {
      _watcher.press(VoiceControl.values[id]);
    }
  }

  void _sendLogged() => _send().catchError((Object e, StackTrace s) {
        Log.onError(e, s, content: "Could not update the Dock menu");
      });

  Future<void> _send() => _channel.invokeMethod("setItems", [
        for (final button in _watcher.state.controls)
          {"id": button.control.index, "title": button.label},
      ]);
}
