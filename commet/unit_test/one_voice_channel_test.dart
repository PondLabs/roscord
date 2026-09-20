// Walking into a voice channel leaves whichever one is already being stood
// in: nobody is ever in two at once.
import 'package:commet/client/call_manager.dart';
import 'package:commet/client/client.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:test/test.dart';

class _Client implements Client {
  _Client(this.identifier);
  @override
  final String identifier;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements VoipSession {
  _Session(this.client, this.roomId, this.state);

  @override
  final Client client;
  @override
  final String roomId;
  @override
  final VoipState state;

  @override
  String get roomName => roomId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final me = _Client('me');
  final otherAccount = _Client('other');

  List<String> leaving(List<VoipSession> sessions,
          {Client? on, String? join}) =>
      CallManager.callsToLeave(sessions, on ?? me, join ?? '!new')
          .map((s) => '${s.client.identifier}${s.roomId}')
          .toList();

  test('the channel already being stood in is left', () {
    final sessions = [_Session(me, '!old', VoipState.connected)];
    expect(leaving(sessions), ['me!old']);
  });

  test('several at once are all left, so none is missed', () {
    final sessions = [
      _Session(me, '!old', VoipState.connected),
      _Session(me, '!older', VoipState.connecting),
    ];
    expect(leaving(sessions), ['me!old', 'me!older']);
  });

  test('the room being joined is left to its own path', () {
    // MatrixVoipRoomComponent.joinCall hangs its own session up first, and
    // leaving is memoised: naming it here would be a second hang up racing
    // the first (issue #48).
    final sessions = [_Session(me, '!new', VoipState.connected)];
    expect(leaving(sessions), isEmpty);
  });

  test('a call that is still ringing is not answered by leaving it', () {
    final sessions = [_Session(me, '!ringing', VoipState.incoming)];
    expect(leaving(sessions), isEmpty);
  });

  test('a call already over is not hung up again', () {
    final sessions = [_Session(me, '!done', VoipState.ended)];
    expect(leaving(sessions), isEmpty);
  });

  test('one being placed is left: it is a call being sat in', () {
    final sessions = [_Session(me, '!calling', VoipState.outgoing)];
    expect(leaving(sessions), ['me!calling']);
  });

  test('another account in a room of the same id is still another call', () {
    final sessions = [_Session(otherAccount, '!new', VoipState.connected)];
    expect(leaving(sessions), ['other!new']);
  });

  test('nothing to leave when not in anything', () {
    expect(leaving([]), isEmpty);
  });

  test('everything else goes, whoever it belongs to', () {
    final sessions = [
      _Session(me, '!old', VoipState.connected),
      _Session(otherAccount, '!theirs', VoipState.connected),
      _Session(me, '!ringing', VoipState.incoming),
      _Session(me, '!new', VoipState.connected),
    ];
    expect(leaving(sessions), ['me!old', 'other!theirs']);
  });
}
