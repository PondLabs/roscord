// The call controls shown outside the window (taskbar thumbnail, Dock menu,
// launcher actions, the browser's picture-in-picture panel) behave the way
// Discord's do (issue #146).
import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client_manager.dart';
import 'package:commet/client/components/voip/deafen_rule.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:test/test.dart';

class _Session implements VoipSession {
  _Session(this.state,
      {this.isMicrophoneMuted = false, this.isDeafened = false});

  @override
  final VoipState state;
  @override
  final bool isMicrophoneMuted;
  @override
  final bool isDeafened;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A session in a call that keeps whatever it is told.
class _LiveSession implements VoipSession {
  _LiveSession({this.isMicrophoneMuted = false, this.isDeafened = false});

  @override
  VoipState state = VoipState.connected;
  @override
  bool isMicrophoneMuted;
  @override
  bool isDeafened;

  @override
  Future<void> setMicrophoneMute(bool state) async => isMicrophoneMuted = state;

  @override
  Future<void> setDeafened(bool state) async => isDeafened = state;

  @override
  String get roomName => "voice channel";

  @override
  Future<void> hangUpCall() async => state = VoipState.ended;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A session that mutes and deafens the way the real ones do (DeafenRule).
class _RuleSession implements VoipSession {
  final _rule = DeafenRule();
  bool _micMuted = false;

  @override
  VoipState get state => VoipState.connected;
  @override
  bool get isMicrophoneMuted => _micMuted;
  @override
  bool get isDeafened => _rule.deafened;

  @override
  Future<void> setMicrophoneMute(bool state) async {
    if (!state && _rule.deafened) {
      _rule.unmute();
      _micMuted = false;
      return;
    }
    _micMuted = state;
  }

  @override
  Future<void> setDeafened(bool state) async {
    if (state) {
      _rule.deafen(micMuted: _micMuted);
      _micMuted = true;
    } else {
      _micMuted = _rule.undeafen(micMuted: _micMuted);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Presses [control] as a surface drawn for [session] (and [others]) would.
void _press(VoiceControl control, _LiveSession session,
    {List<_LiveSession> others = const []}) {
  final calls = CallManager(ClientManager());
  calls.currentSessions.addAll([session, ...others]);
  VoiceCallState.of(calls.currentSessions).press(control, calls);
}

/// What a surface draws: the control, whether it shows its slashed (active)
/// icon, and its tooltip or menu label.
List<(VoiceControl, bool, String)> _shown(List<VoipSession> sessions) =>
    VoiceCallState.of(sessions)
        .controls
        .map((c) => (c.control, c.active, c.label))
        .toList();

void main() {
  group("Which controls show", () {
    test("none outside a call", () {
      expect(VoiceCallState.of([]).controls, isEmpty);
    });

    test("mute, deafen and disconnect while heard in a call", () {
      expect(_shown([_Session(VoipState.connected)]), [
        (VoiceControl.mute, false, "Mute"),
        (VoiceControl.deafen, false, "Deafen"),
        (VoiceControl.disconnect, false, "Disconnect"),
      ]);
    });

    test("a slashed mic offering to unmute while muted", () {
      expect(_shown([_Session(VoipState.connected, isMicrophoneMuted: true)]),
          contains((VoiceControl.mute, true, "Unmute")));
    });

    test("deafened shows both slashed, as deafened counts as muted", () {
      expect(_shown([_Session(VoipState.connected, isDeafened: true)]), [
        (VoiceControl.mute, true, "Unmute"),
        (VoiceControl.deafen, true, "Undeafen"),
        (VoiceControl.disconnect, false, "Disconnect"),
      ]);
    });
  });

  group("Pressing a control", () {
    test("mute mutes someone heard", () {
      final session = _LiveSession();
      _press(VoiceControl.mute, session);
      expect(session.isMicrophoneMuted, isTrue);
    });

    test("unmute unmutes someone muted", () {
      final session = _LiveSession(isMicrophoneMuted: true);
      _press(VoiceControl.mute, session);
      expect(session.isMicrophoneMuted, isFalse);
    });

    test("deafen deafens, and undeafen undeafens", () {
      final heard = _LiveSession();
      _press(VoiceControl.deafen, heard);
      expect(heard.isDeafened, isTrue);

      final deafened = _LiveSession(isDeafened: true);
      _press(VoiceControl.deafen, deafened);
      expect(deafened.isDeafened, isFalse);
    });

    test("disconnect leaves the call, but does not decline one ringing", () {
      final call = _LiveSession();
      final ringing = _LiveSession()..state = VoipState.incoming;
      _press(VoiceControl.disconnect, call, others: [ringing]);
      expect(call.state, VoipState.ended);
      expect(ringing.state, VoipState.incoming);
    });

    test("unmute while deafened, having muted first, is heard again", () {
      // Discord: Unmute clears both, whatever the mute under the deafen.
      final calls = CallManager(ClientManager());
      final session = _RuleSession();
      calls.currentSessions.add(session);
      calls.mute();
      calls.deafen();

      VoiceCallState.of(calls.currentSessions).press(VoiceControl.mute, calls);
      expect((session.isMicrophoneMuted, session.isDeafened), (false, false));
    });
  });
}
