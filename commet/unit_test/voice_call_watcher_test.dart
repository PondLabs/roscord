// One watcher tells every surface outside the window (tray, taskbar
// thumbnail, Dock menu, launcher quicklist, browser panel) what the call
// looks like, and only when that changes (issue #146).
import 'dart:async';

import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client_manager.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:test/test.dart';

class _Session implements VoipSession {
  @override
  VoipState state = VoipState.connected;
  @override
  bool isMicrophoneMuted = false;
  @override
  bool isDeafened = false;

  @override
  Future<void> setMicrophoneMute(bool state) async {
    isMicrophoneMuted = state;
    changed();
  }

  final _changed = StreamController<void>.broadcast();
  @override
  Stream<void> get onStateChanged => _changed.stream;

  void changed() => _changed.add(null);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _heard = VoiceCallState(inCall: true, muted: false, deafened: false);

void main() {
  late CallManager calls;
  late VoiceCallWatcher watcher;
  late List<VoiceCallState> told;

  setUp(() {
    calls = CallManager(ClientManager());
    watcher = VoiceCallWatcher(() => calls)..start(poll: null);
    told = [];
    watcher.changes.listen(told.add);
  });

  tearDown(() => watcher.stop());

  test("tells when a call is joined", () async {
    calls.currentSessions.add(_Session());
    await pumpEventQueue();
    expect(told, [_heard]);
    expect(watcher.state, _heard);
  });

  test("tells when the session says its mute changed", () async {
    final session = _Session();
    calls.currentSessions.add(session);
    await pumpEventQueue();

    session.isMicrophoneMuted = true;
    session.changed();
    await pumpEventQueue();
    expect(told.last,
        const VoiceCallState(inCall: true, muted: true, deafened: false));
  });

  test("says nothing when nothing it shows has changed", () async {
    final session = _Session();
    calls.currentSessions.add(session);
    await pumpEventQueue();

    session.changed();
    await pumpEventQueue();
    expect(told, [_heard]);
  });

  test("follows the call manager an app refresh puts in its place", () async {
    calls = CallManager(ClientManager());
    watcher.refresh(); // What the poll does every second.

    calls.currentSessions.add(_Session());
    await pumpEventQueue();
    expect(told, [_heard]);
  });

  test("a press acts on the call as shown, and the change is told", () async {
    final session = _Session();
    calls.currentSessions.add(session);
    await pumpEventQueue();

    watcher.press(VoiceControl.mute);
    await pumpEventQueue();
    expect(session.isMicrophoneMuted, isTrue);
    expect(told.last.muted, isTrue);
  });
}
