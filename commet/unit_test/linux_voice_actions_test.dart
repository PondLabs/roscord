// On Linux the launcher's right-click menu (GNOME dash, Plasma task manager,
// Ubuntu Dock, Cinnamon, XFCE, Plank) offers the call controls as desktop
// file actions (issue #146). Each runs `commet --shortcut <name>`, which
// linux/shortcuts.h hands to the running app over D-Bus.
import 'dart:io';

import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client_manager.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/utils/system_wide_shortcuts/system_wide_shortcuts_linux.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:dbus/dbus.dart';
import 'package:test/test.dart';

class _Session implements VoipSession {
  @override
  VoipState state = VoipState.connected;
  @override
  bool isMicrophoneMuted = false;
  @override
  bool isDeafened = false;
  @override
  String get roomName => "voice channel";
  @override
  Stream<void> get onStateChanged => const Stream.empty();
  @override
  Future<void> hangUpCall() async => state = VoipState.ended;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _desktopFiles = [
  "linux/flatpak/chat.commet.commetapp.desktop",
  "linux/debian/usr/share/applications/chat.commet.commetapp.desktop",
];

/// The `[Desktop Action]` groups of [path], by id, as their Exec lines.
Map<String, String> _actions(String path) {
  final actions = <String, String>{};
  String? group;
  for (final line in File(path).readAsLinesSync()) {
    final header = RegExp(r"^\[Desktop Action (.+)\]$").firstMatch(line);
    if (header != null) {
      group = header.group(1);
    } else if (line.startsWith("[")) {
      group = null;
    } else if (group != null && line.startsWith("Exec=")) {
      actions[group] = line.substring("Exec=".length);
    }
  }
  return actions;
}

void main() {
  for (final path in _desktopFiles) {
    group(path, () {
      test("offers mute, deafen and disconnect", () {
        final listed = File(path)
            .readAsLinesSync()
            .firstWhere((l) => l.startsWith("Actions="))
            .substring("Actions=".length)
            .split(";")
            .where((a) => a.isNotEmpty);
        expect(listed, ["ToggleMute", "ToggleDeafen", "Disconnect"]);
        expect(_actions(path).keys, listed);
      });

      test("asks the running app for things it answers on D-Bus", () {
        for (final exec in _actions(path).values) {
          final name = RegExp(r"--shortcut (\S+)").firstMatch(exec)?.group(1);
          expect(ShortcutsObject.methods, contains(name), reason: exec);
        }
      });
    });
  }

  test("Disconnect, over D-Bus, leaves the call", () async {
    final calls = CallManager(ClientManager());
    final session = _Session();
    calls.currentSessions.add(session);
    final watcher = VoiceCallWatcher(() => calls)..start(poll: null);
    addTearDown(watcher.stop);

    await ShortcutsObject(calls: watcher).handleMethodCall(const DBusMethodCall(
        sender: ":1.42",
        interface: "chat.commet.commetapp.Shortcuts",
        name: "disconnect"));
    expect(session.state, VoipState.ended);
  });
}
