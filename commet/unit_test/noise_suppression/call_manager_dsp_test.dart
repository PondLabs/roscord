// CallManager tells the voice DSP when calls start and end. A session that
// never leaves its list keeps the DSP (and the system audio loopback)
// running after the call and hides the microphone test, the one tool for
// hearing what noise suppression does.
import 'dart:async';

import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client.dart';
import 'package:commet/client/client_manager.dart';
import 'package:commet/client/components/voip/audio_processing/audio_processing_manager.dart';
import 'package:commet/client/components/voip/audio_processing/audio_processing_manager_stub.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Client implements Client {
  @override
  Room? getRoom(String identifier) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A LiveKit session: every one of them reports an empty sessionId and is
/// only equal to itself.
class _LivekitSession implements VoipSession {
  @override
  final Client client;
  _LivekitSession(this.client);

  @override
  String get sessionId => "";
  @override
  String get roomId => "!room";
  @override
  VoipState state = VoipState.connecting;
  @override
  bool get isDeafened => false;
  @override
  Stream<VoipState> get onConnectionStateChanged => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// MatrixVoipSession: MatrixVoipComponent hands out a new one for each event
/// about the same call, equal by call id.
class _LegacySession implements VoipSession {
  @override
  final Client client;
  final String callId;
  _LegacySession(this.client, this.callId);

  @override
  String get sessionId => "client_$callId";
  @override
  String get roomId => "!dm";
  @override
  VoipState state = VoipState.connecting;
  @override
  bool get isDeafened => false;
  @override
  Stream<VoipState> get onConnectionStateChanged => const Stream.empty();

  @override
  bool operator ==(Object other) =>
      other is _LegacySession && other.sessionId == sessionId;
  @override
  int get hashCode => sessionId.hashCode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingDsp extends UnsupportedAudioProcessingManager {
  final List<VoipSession> started = [];
  final List<VoipSession> ended = [];

  @override
  Future<void> onSessionStarted(VoipSession session) async =>
      started.add(session);

  @override
  Future<void> onSessionEnded(VoipSession session) async => ended.add(session);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RecordingDsp dsp;
  late CallManager calls;
  final client = _Client();

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await preferences.init();
  });

  setUp(() {
    dsp = _RecordingDsp();
    // ignore: invalid_use_of_visible_for_testing_member
    AudioProcessingManager.debugInstance = dsp;
    calls = CallManager(ClientManager());
  });

  // ignore: invalid_use_of_visible_for_testing_member
  tearDown(() => AudioProcessingManager.debugInstance = null);

  test('a legacy call ends through a different wrapper of the same call', () {
    calls.onClientSessionStarted(_LegacySession(client, "call-1"));
    calls.onSessionEnded(_LegacySession(client, "call-1"));

    expect(calls.currentSessions, isEmpty);
    expect(dsp.ended, [_LegacySession(client, "call-1")],
        reason: 'the DSP was never told the call ended');
  });

  // Issue #48: every LiveKit session has sessionId "", so a late hang up of
  // the previous call must not take the rejoined one with it.
  test('ending one LiveKit session leaves the other one registered', () {
    final previous = _LivekitSession(client);
    final rejoined = _LivekitSession(client);
    calls.onClientSessionStarted(previous);
    calls.onClientSessionStarted(rejoined);

    calls.onSessionEnded(previous);

    expect(calls.currentSessions, [same(rejoined)]);
    expect(dsp.ended, [same(previous)]);
  });
}
