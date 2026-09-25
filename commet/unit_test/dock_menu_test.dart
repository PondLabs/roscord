// The call controls in roscord's Dock menu on macOS (issue #146). The
// runner builds the menu each time the Dock asks (AppDelegate.swift), from
// the items this sends it.
import 'dart:async';

import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client_manager.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/utils/voice_controls/dock_menu.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
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
  Future<void> setDeafened(bool state) async {
    isDeafened = state;
    _changed.add(null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel("test/dock");
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late CallManager calls;
  late VoiceCallWatcher watcher;
  late DockMenu dock;
  late List<List<String>> sent;

  setUp(() {
    sent = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == "setItems") {
        sent.add([
          for (final item in (call.arguments as List).cast<Map>())
            "${item["id"]}:${item["title"]}",
        ]);
      }
      return null;
    });
    calls = CallManager(ClientManager());
    watcher = VoiceCallWatcher(() => calls)..start(poll: null);
    dock = DockMenu(channel: channel, watcher: watcher);
  });

  tearDown(() async {
    await dock.stop();
    watcher.stop();
  });

  test("nothing of ours in the menu outside a call", () async {
    await dock.start();
    expect(sent.last, isEmpty);
  });

  test("the controls' labels once in a call, following it", () async {
    await dock.start();
    final session = _Session()..isMicrophoneMuted = true;
    calls.currentSessions.add(session);
    await pumpEventQueue();
    expect(sent.last, ["0:Unmute", "1:Deafen", "2:Disconnect"]);
  });

  test("choosing an item presses its control", () async {
    final session = _Session();
    calls.currentSessions.add(session);
    await dock.start();

    await messenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
            MethodCall("onItemClicked", {"id": VoiceControl.deafen.index})),
        (_) {});
    await pumpEventQueue();
    expect(session.isDeafened, isTrue);
    expect(sent.last, ["0:Unmute", "1:Undeafen", "2:Disconnect"]);
  });
}
