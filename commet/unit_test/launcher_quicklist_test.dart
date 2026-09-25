// The launcher quicklist on Linux: docks that read Unity's LauncherEntry
// quicklists (Ubuntu Dock, Dash to Dock, Plank) show the call controls in
// the app icon's menu, with labels that follow the call (issue #146).
import 'dart:async';
import 'dart:io';

import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client_manager.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/utils/voice_controls/launcher_quicklist.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:dbus/dbus.dart';
import 'package:test/test.dart';

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

/// The items under the root of a dbusmenu layout: (id, label, icon name).
List<(int, String, String)> _items(DBusStruct layout) {
  final children = (layout.children[2] as DBusArray).children;
  return [
    for (final child in children)
      () {
        final item = (child as DBusVariant).value as DBusStruct;
        final props = (item.children[1] as DBusDict).mapStringVariant();
        return (
          (item.children[0] as DBusInt32).value,
          (props["label"] as DBusString).value,
          (props["icon-name"] as DBusString).value,
        );
      }(),
  ];
}

void main() {
  group("Quicklist layout", () {
    test("empty outside a call", () {
      expect(_items(QuicklistMenu.layoutOf(VoiceCallState.idle)), isEmpty);
    });

    test("the controls, with themed icons, while in a call", () {
      const muted = VoiceCallState(inCall: true, muted: true, deafened: false);
      expect(_items(QuicklistMenu.layoutOf(muted)), [
        (1, "Unmute", "microphone-sensitivity-muted-symbolic"),
        (2, "Deafen", "audio-headphones-symbolic"),
        (3, "Disconnect", "call-stop-symbolic"),
      ]);
    });
  });

  group("On the bus", () {
    late DBusServer server;
    late DBusClient app;
    late DBusClient dock;
    late Directory socketDir;
    late CallManager calls;
    late VoiceCallWatcher watcher;
    late LauncherQuicklist quicklist;

    setUp(() async {
      socketDir = await Directory.systemTemp.createTemp("quicklist-test");
      server = DBusServer();
      final address =
          await server.listenAddress(DBusAddress.unix(dir: socketDir));
      app = DBusClient(address);
      dock = DBusClient(address);
      calls = CallManager(ClientManager());
      watcher = VoiceCallWatcher(() => calls)..start(poll: null);
      quicklist = LauncherQuicklist(bus: app, watcher: watcher);
    });

    tearDown(() async {
      await quicklist.stop();
      watcher.stop();
      await app.close();
      await dock.close();
      await server.close();
      await socketDir.delete(recursive: true);
    });

    /// What a dock learns when the app announces itself: the quicklist's
    /// owner and path.
    (String, DBusObjectPath) readUpdate(DBusSignal update) {
      expect((update.values[0] as DBusString).value,
          "application://chat.commet.commetapp.desktop");
      final props = (update.values[1] as DBusDict).mapStringVariant();
      return (update.sender!, props["quicklist"] as DBusObjectPath);
    }

    test("a dock reads the controls, and a click on one presses it", () async {
      final session = _Session();
      calls.currentSessions.add(session);
      await pumpEventQueue();

      final update = DBusSignalStream(dock,
              interface: "com.canonical.Unity.LauncherEntry", name: "Update")
          .first;
      await dock.listNames(); // So the bus has the match rule first.
      await quicklist.start();
      final (owner, path) = readUpdate(await update);

      final layout = await dock.callMethod(
          destination: owner,
          path: path,
          interface: "com.canonical.dbusmenu",
          name: "GetLayout",
          values: [
            const DBusInt32(0),
            const DBusInt32(-1),
            DBusArray.string([]),
          ]);
      expect(_items(layout.values[1] as DBusStruct).map((i) => i.$2),
          ["Mute", "Deafen", "Disconnect"]);

      await dock.callMethod(
          destination: owner,
          path: path,
          interface: "com.canonical.dbusmenu",
          name: "Event",
          values: [
            const DBusInt32(1),
            const DBusString("clicked"),
            const DBusVariant(DBusInt32(0)),
            const DBusUint32(0),
          ]);
      expect(session.isMicrophoneMuted, isTrue);
    });

    test("tells the dock to read it again when the call changes", () async {
      await quicklist.start();
      final updated = DBusSignalStream(dock,
              interface: "com.canonical.dbusmenu",
              name: "LayoutUpdated",
              path: LauncherQuicklist.menuPath)
          .first;
      await dock.listNames();

      calls.currentSessions.add(_Session());
      await expectLater(updated, completes);
    });
  });
}
