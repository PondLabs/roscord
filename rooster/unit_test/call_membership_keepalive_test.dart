// Someone who stays in a voice channel for hours has to stay listed in it.
// A call membership lapses four hours after it was last written (MatrixRTC's
// window, counted from the join), and its owner is the one who pushes that
// out. We only did so from the delayed-leave heartbeat: on a homeserver
// without delayed events, or once that heartbeat had failed to start, nobody
// did, and four hours in the member vanished from everyone's list while
// still talking. It was also pushed out only in its last hour, by this
// machine's clock, so a clock an hour behind let it lapse first.
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:rooster/client/client.dart';
import 'package:rooster/client/components/activities/activities_component.dart';
import 'package:rooster/client/components/profile/profile_component.dart';
import 'package:rooster/client/components/user_presence/user_idle_watcher.dart';
import 'package:rooster/client/components/voip/audio_processing/audio_processing_manager.dart';
import 'package:rooster/client/components/voip/audio_processing/audio_processing_manager_stub.dart';
import 'package:rooster/client/components/voip/voip_session.dart';
import 'package:rooster/client/matrix/components/voip_room/matrix_call_membership.dart';
import 'package:rooster/client/matrix/components/voip_room/matrix_livekit_voip_session.dart';
import 'package:rooster/client/matrix/components/voip_room/matrix_voip_room_component.dart';
import 'package:rooster/client/matrix/matrix_room.dart';
import 'package:rooster/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' as matrix;
import 'package:shared_preferences/shared_preferences.dart';

import 'noise_suppression/fakes.dart';

const _me = '@me:example.org';
const _ownKey = '_${_me}_DEVICE_m.call';

class _LocalPublication
    implements lk.LocalTrackPublication<lk.LocalAudioTrack> {
  _LocalPublication(this.sid, this.track, this.participant);

  @override
  final lk.LocalParticipant participant;

  @override
  final String sid;

  @override
  lk.LocalAudioTrack? track;

  @override
  lk.TrackSource get source => lk.TrackSource.microphone;

  @override
  bool muted = false;

  @override
  lk.TrackType get kind => lk.TrackType.AUDIO;

  @override
  String get name => source.name;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LocalParticipant implements lk.LocalParticipant {
  final List<_LocalPublication> publications = [];

  @override
  String get identity => '$_me:DEVICE';

  @override
  Map<String, lk.LocalTrackPublication> get trackPublications =>
      {for (final p in publications) p.sid: p};

  @override
  List<lk.LocalTrackPublication<lk.LocalAudioTrack>>
      get audioTrackPublications => publications;

  @override
  bool get isMuted => publications.firstOrNull?.muted ?? true;

  @override
  bool isCameraEnabled() => false;

  @override
  bool isScreenShareEnabled() => false;

  @override
  lk.LocalTrackPublication? getTrackPublicationBySource(
          lk.TrackSource source) =>
      publications.firstWhereOrNull((p) => p.source == source);

  @override
  Future<void> publishData(List<int> data,
      {bool? reliable,
      List<String>? destinationIdentities,
      String? topic}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Someone in the LiveKit room who publishes nothing: a microphone that
/// would not open, or none at all.
class _RemoteParticipant implements lk.RemoteParticipant {
  _RemoteParticipant(this.identity);

  @override
  final String identity;

  @override
  bool get isSpeaking => false;

  @override
  Map<String, lk.RemoteTrackPublication> get trackPublications => const {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Listener implements lk.EventsListener<lk.RoomEvent> {
  @override
  Future<void> Function() on<E>(FutureOr<void> Function(E) then,
          {bool Function(E)? filter}) =>
      () async {};

  @override
  Future<bool> dispose() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Room implements lk.Room {
  _Room(this.localParticipant);

  @override
  final lk.LocalParticipant? localParticipant;

  final Map<String, lk.RemoteParticipant> remote = {};

  @override
  lk.ConnectionState connectionState = lk.ConnectionState.connected;

  @override
  UnmodifiableMapView<String, lk.RemoteParticipant> get remoteParticipants =>
      UnmodifiableMapView(remote);

  @override
  lk.EventsListener<lk.RoomEvent> createListener({bool synchronized = false}) =>
      _Listener();

  @override
  Future<void> disconnect() async {}

  @override
  Future<bool> dispose() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The homeserver, as far as our membership goes.
class _SdkClient implements matrix.Client {
  @override
  final String? deviceID = 'DEVICE';

  @override
  final String? userID = _me;

  /// Whether the homeserver has delayed events (MSC4140). Synapse ships
  /// without them.
  bool delayedEvents = false;

  /// How many of the next requests for the homeserver's versions fail.
  int versionsFailures = 0;
  int versionsAsked = 0;

  /// How many of the next delayed leaves fail to be scheduled.
  int armFailures = 0;
  int armAttempts = 0;

  /// How many of the next restarts of the delayed leave are lost, and how
  /// many were asked for.
  int restartsLost = 0;
  int restarts = 0;

  /// Our membership as written, write by write.
  final List<Map<String, Object?>> membershipWrites = [];

  @override
  Future<matrix.GetVersionsResponse> getVersions({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async {
    versionsAsked++;
    if (versionsFailures > 0) {
      versionsFailures--;
      throw Exception('offline');
    }
    return matrix.GetVersionsResponse(
        versions: const ['v1.11'],
        unstableFeatures: {if (delayedEvents) 'org.matrix.msc4140': true});
  }

  @override
  Future<String> setRoomStateWithKey(String roomId, String eventType,
      String stateKey, Map<String, Object?> body) async {
    expect(eventType, MatrixVoipRoomComponent.callMemberStateEvent);
    expect(stateKey, _ownKey);
    membershipWrites.add(body);
    return '\$written${membershipWrites.length}';
  }

  @override
  Future<Map<String, Object?>> request(matrix.RequestType type, String action,
      {dynamic data = '',
      String contentType = 'application/json',
      Map<String, Object?>? query}) async {
    if (query?.containsKey('org.matrix.msc4140.delay') == true) {
      armAttempts++;
      if (armFailures > 0) {
        armFailures--;
        throw Exception('M_LIMIT_EXCEEDED');
      }
      return {'delay_id': 'delay-$armAttempts'};
    }
    // Restarting, sending or cancelling a delayed leave.
    if (data is String && data.contains('restart')) {
      restarts++;
      if (restartsLost > 0) {
        restartsLost--;
        // Sent down a connection that died: no answer ever comes.
        return Completer<Map<String, Object?>>().future;
      }
    }
    return {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SdkRoom implements matrix.Room {
  @override
  final String id = '!room:example.org';

  @override
  final _SdkClient client = _SdkClient();

  @override
  final Map<String, Map<String, matrix.StrippedStateEvent>> states = {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Profile implements Profile {
  @override
  final String identifier = _me;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements Client {
  @override
  final String identifier = _me;

  @override
  final Profile? self = _Profile();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MatrixRoom implements MatrixRoom {
  @override
  final _SdkRoom matrixRoom = _SdkRoom();

  @override
  final Client client = _Client();

  @override
  final String identifier = '!room:example.org';

  @override
  final String displayName = 'Voice';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeWebrtcChannel webrtc;
  late _Room livekit;
  late _MatrixRoom room;
  late _SdkClient homeserver;
  MatrixLivekitVoipSession? session;

  // The homeserver's clock, which memberships lapse by, and this machine's.
  late DateTime serverTime;
  late DateTime localTime;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await preferences.init();
    // ignore: invalid_use_of_visible_for_testing_member
    AudioProcessingManager.debugInstance = UnsupportedAudioProcessingManager();
  });

  setUp(() async {
    (webrtc = FakeWebrtcChannel()).install();
    final (mic, _) = await publishedMicrophone(
        const lk.AudioCaptureOptions(noiseSuppression: true));
    final participant = _LocalParticipant();
    participant.publications.add(_LocalPublication('TR_mic', mic, participant));
    livekit = _Room(participant);
    room = _MatrixRoom();
    homeserver = room.matrixRoom.client;
    serverTime = DateTime(2026, 9, 26, 12);
    // Three hours behind: going by it, every window was written three hours
    // short, and pushed out two hours after it had closed for everyone.
    localTime = serverTime.subtract(const Duration(hours: 3));
    session = null;
  });

  tearDown(() async {
    session?.state = VoipState.ended;
    UserIdleWatcher.instance.isAway.value = false;
    webrtc.uninstall();
  });

  /// Our membership as the join wrote it, [at] by the homeserver's clock.
  void joined(DateTime at) {
    room.matrixRoom.states[MatrixVoipRoomComponent.callMemberStateEvent] = {
      _ownKey: matrix.Event(
        type: MatrixVoipRoomComponent.callMemberStateEvent,
        content: {
          'application': 'm.call',
          'call_id': '',
          'device_id': 'DEVICE',
          'expires': MatrixCallMembership.lifetime.inMilliseconds,
          'scope': 'm.room',
          'chat.commet.streams': <String>[],
        },
        senderId: _me,
        stateKey: _ownKey,
        eventId: r'$join',
        originServerTs: at,
        room: room.matrixRoom,
      ),
    };
  }

  /// Joins, then lets the initial heartbeat and state debounce settle before
  /// tests advance the simulated membership clocks by minutes or hours.
  Future<MatrixLivekitVoipSession> join() async {
    final joinedSession = MatrixLivekitVoipSession(room, livekit,
        // ignore: invalid_use_of_visible_for_testing_member
        now: () => localTime,
        // ignore: invalid_use_of_visible_for_testing_member
        serverNow: () => serverTime);
    session = joinedSession;
    // ignore: invalid_use_of_visible_for_testing_member
    await joinedSession.debugHeartbeat();
    await Future<void>.delayed(const Duration(seconds: 1));
    return joinedSession;
  }

  /// [by] of call, on both clocks, then a heartbeat.
  Future<void> stay(Duration by) async {
    serverTime = serverTime.add(by);
    localTime = localTime.add(by);
    // ignore: invalid_use_of_visible_for_testing_member
    await session!.debugHeartbeat();
    await pumpEventQueue();
  }

  DateTime? expiryOf(Map<String, Object?> written) =>
      MatrixCallMembership.expiresAt(written, serverTime);

  group('on a homeserver without delayed events', () {
    test('joining without a microphone publishes the initial mute', () async {
      joined(serverTime);
      (livekit.localParticipant! as _LocalParticipant).publications.clear();
      final call = await join();

      expect(call.isMicrophoneMuted, isTrue);
      // No track event or user toggle follows a denied microphone.
      expect(homeserver.membershipWrites, isNotEmpty,
          reason: 'people outside the call must see the initial mute');
      final write = homeserver.membershipWrites.single;
      expect(MatrixCallMembership.voiceStateOf(write), {VoiceState.muted});
      expect(write[MatrixCallMembership.unguardedKey], isTrue);
    });

    test('our membership is pushed out an hour after it was written', () async {
      final joinedAt = serverTime;
      joined(joinedAt);
      await join();

      await stay(const Duration(minutes: 59));
      expect(homeserver.membershipWrites, isEmpty,
          reason: 'more than three hours of it are left');

      await stay(const Duration(minutes: 2));
      final write = homeserver.membershipWrites.single;
      expect(write['application'], 'm.call');
      expect(write['created_ts'], joinedAt.millisecondsSinceEpoch,
          reason: 'still the same join, to everyone reading it');
      expect(expiryOf(write), serverTime.add(MatrixCallMembership.lifetime));
    });

    // Away was only published with the delayed leave armed: here someone
    // away read as present (green) to everyone else in the channel.
    test('going away is published all the same', () async {
      joined(serverTime);
      await join();
      UserIdleWatcher.instance.isAway.value = true;
      await stay(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(homeserver.membershipWrites.map(MatrixCallMembership.isAway),
          contains(true));
    });

    // A mute, a stream and the DJ booth were too: with no delayed events
    // nobody outside the call ever saw who was muted or live in it.
    test('a mute is published all the same, and says nothing guards it',
        () async {
      joined(serverTime);
      await join();
      (livekit.localParticipant! as _LocalParticipant)
          .publications
          .single
          .muted = true;
      // Any change to what we advertise writes all of it.
      UserIdleWatcher.instance.isAway.value = true;
      await stay(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(seconds: 1));

      final write = homeserver.membershipWrites.last;
      expect(MatrixCallMembership.voiceStateOf(write), {VoiceState.muted});
      expect(write[MatrixCallMembership.unguardedKey], isTrue,
          reason: 'readers drop it once it stops being written');
    });

    test('with nothing to leave behind, it is not called unguarded', () async {
      joined(serverTime);
      await join();
      UserIdleWatcher.instance.isAway.value = true;
      await stay(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(seconds: 1));

      final write = homeserver.membershipWrites.last;
      expect(MatrixCallMembership.voiceStateOf(write), isEmpty);
      expect(write[MatrixCallMembership.unguardedKey], isFalse);
    });

    test('and an hour after that again, still from the same join', () async {
      final joinedAt = serverTime;
      joined(joinedAt);
      await join();
      await stay(const Duration(minutes: 61));
      // What the homeserver sends back once it has taken the write.
      room.matrixRoom
              .states[MatrixVoipRoomComponent.callMemberStateEvent]![_ownKey] =
          matrix.Event(
        type: MatrixVoipRoomComponent.callMemberStateEvent,
        content: homeserver.membershipWrites.single,
        senderId: _me,
        stateKey: _ownKey,
        eventId: r'$written',
        originServerTs: serverTime,
        room: room.matrixRoom,
      );
      // Writes are spaced out (the rate limit is shared with messages).
      await Future<void>.delayed(const Duration(milliseconds: 2100));

      await stay(const Duration(minutes: 30));
      expect(homeserver.membershipWrites, hasLength(1),
          reason: 'three and a half hours of it are left');

      await stay(const Duration(minutes: 31));
      expect(homeserver.membershipWrites, hasLength(2));
      final second = homeserver.membershipWrites.last;
      expect(second['created_ts'], joinedAt.millisecondsSinceEpoch);
      expect(expiryOf(second), serverTime.add(MatrixCallMembership.lifetime));
    });

    test("the homeserver's time lagging behind ours does not cut it short",
        () async {
      joined(serverTime);
      await join();

      // Just woken from a sleep, before a sync has said what time it is:
      // what we know of the homeserver's time lags behind.
      localTime = serverTime.add(const Duration(minutes: 61));
      serverTime = serverTime.add(const Duration(minutes: 1));
      // ignore: invalid_use_of_visible_for_testing_member
      await session!.debugHeartbeat();
      await pumpEventQueue();

      expect(expiryOf(homeserver.membershipWrites.single),
          localTime.add(MatrixCallMembership.lifetime));
    });

    test("this machine's clock being set back does not hold it up", () async {
      joined(serverTime);
      await join();
      await stay(const Duration(minutes: 61));
      room.matrixRoom
              .states[MatrixVoipRoomComponent.callMemberStateEvent]![_ownKey] =
          matrix.Event(
        type: MatrixVoipRoomComponent.callMemberStateEvent,
        content: homeserver.membershipWrites.single,
        senderId: _me,
        stateKey: _ownKey,
        eventId: r'$written',
        originServerTs: serverTime,
        room: room.matrixRoom,
      );
      await Future<void>.delayed(const Duration(milliseconds: 2100));

      // An hour on, and someone fixed a clock that ran three hours ahead.
      serverTime = serverTime.add(const Duration(minutes: 61));
      localTime = localTime.subtract(const Duration(hours: 2));
      // ignore: invalid_use_of_visible_for_testing_member
      await session!.debugHeartbeat();
      await pumpEventQueue();

      expect(homeserver.membershipWrites, hasLength(2));
      expect(expiryOf(homeserver.membershipWrites.last),
          serverTime.add(MatrixCallMembership.lifetime));
    });

    test('nothing asks the homeserver about delayed events again and again',
        () async {
      joined(serverTime);
      await join();
      for (var i = 0; i < 6; i++) {
        await stay(const Duration(seconds: 10));
      }

      expect(homeserver.versionsAsked, 1);
      expect(homeserver.armAttempts, 0);
    });
  });

  group('with delayed events', () {
    setUp(() => homeserver.delayedEvents = true);

    test('our membership is pushed out an hour after it was written, too',
        () async {
      joined(serverTime.subtract(const Duration(minutes: 59)));
      await join();
      expect(session!.heartbeatDelayId, isNotNull);

      await stay(const Duration(minutes: 2));
      // Arming the delayed leave published what we advertise, which waits
      // a moment to settle; the push out goes with it.
      await Future<void>.delayed(const Duration(seconds: 1));

      final write = homeserver.membershipWrites.single;
      expect(expiryOf(write), serverTime.add(MatrixCallMembership.lifetime));
    });

    test('a mute goes out guarded by the delayed leave', () async {
      joined(serverTime);
      await join();
      expect(session!.heartbeatDelayId, isNotNull);
      (livekit.localParticipant! as _LocalParticipant)
          .publications
          .single
          .muted = true;
      UserIdleWatcher.instance.isAway.value = true;
      await stay(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(seconds: 1));

      final write = homeserver.membershipWrites.last;
      expect(MatrixCallMembership.voiceStateOf(write), {VoiceState.muted});
      expect(write[MatrixCallMembership.unguardedKey], isFalse);
    });

    test('pushing it out keeps saying we are away', () async {
      UserIdleWatcher.instance.isAway.value = true;
      joined(serverTime.subtract(const Duration(hours: 1, minutes: 1)));
      await join();
      await Future<void>.delayed(const Duration(seconds: 1));

      final write = homeserver.membershipWrites.single;
      expect(MatrixCallMembership.isAway(write), isTrue);
      expect(expiryOf(write), serverTime.add(MatrixCallMembership.lifetime));
    });

    test('a delayed leave that could not be scheduled is tried again',
        () async {
      homeserver.armFailures = 1;
      joined(serverTime);
      await join();
      expect(session!.heartbeatDelayId, isNull);

      await stay(const Duration(seconds: 10));
      expect(homeserver.armAttempts, 1, reason: 'not straight away');

      await stay(const Duration(seconds: 30));
      expect(homeserver.armAttempts, 2);
      expect(session!.heartbeatDelayId, isNotNull);
    });

    test('one that keeps failing is tried less and less often', () async {
      homeserver.armFailures = 3;
      joined(serverTime);
      await join();
      await stay(const Duration(seconds: 30));
      expect(homeserver.armAttempts, 2);

      await stay(const Duration(seconds: 30));
      expect(homeserver.armAttempts, 2, reason: 'a minute after the second');
      await stay(const Duration(seconds: 30));
      expect(homeserver.armAttempts, 3);

      await stay(const Duration(minutes: 1, seconds: 50));
      expect(homeserver.armAttempts, 3, reason: 'two minutes after the third');
      await stay(const Duration(seconds: 10));
      expect(homeserver.armAttempts, 4);
      expect(session!.heartbeatDelayId, isNotNull);
    });

    test('a restart that was lost does not hold up the next heartbeat',
        () async {
      // ignore: invalid_use_of_visible_for_testing_member
      final timeout = MatrixLivekitVoipSession.restartTimeout;
      // ignore: invalid_use_of_visible_for_testing_member
      MatrixLivekitVoipSession.restartTimeout =
          const Duration(milliseconds: 100);
      // ignore: invalid_use_of_visible_for_testing_member
      addTearDown(() => MatrixLivekitVoipSession.restartTimeout = timeout);

      joined(serverTime);
      await join();
      expect(session!.heartbeatDelayId, isNotNull);

      // The next heartbeat's restart goes down a connection that died with
      // the network. It used to be waited for until the HTTP client gave up
      // (35 s), every heartbeat behind it skipped, and the delayed leave
      // (30 s) took our membership down while we were still in the call.
      homeserver.restartsLost = 1;
      // ignore: invalid_use_of_visible_for_testing_member
      unawaited(session!.debugHeartbeat());
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Ten seconds on, the next one restarts it, well inside the 30 s.
      await stay(const Duration(seconds: 10))
          .timeout(const Duration(seconds: 2));
      expect(homeserver.restarts, 2);
      expect(session!.heartbeatDelayId, isNotNull);
    });

    test('a homeserver that could not be asked is asked again', () async {
      homeserver.versionsFailures = 1;
      joined(serverTime);
      await join();
      expect(session!.heartbeatDelayId, isNull);

      await stay(const Duration(seconds: 40));
      expect(homeserver.versionsAsked, 2);
      expect(session!.heartbeatDelayId, isNotNull);
    });
  });

  group('who is connected', () {
    test('everyone in the LiveKit room, publishing or not', () async {
      livekit.remote['@bob:example.org:BOB'] =
          _RemoteParticipant('@bob:example.org:BOB');
      joined(serverTime);
      final call = await join();

      expect(call.connectedUserIds, {_me, '@bob:example.org'});
    });

    test('someone connecting or leaving is a change to the call', () async {
      joined(serverTime);
      final call = await join();
      final changes = <void>[];
      final sub = call.onStateChanged.listen(changes.add);
      addTearDown(sub.cancel);

      final bob = _RemoteParticipant('@bob:example.org:BOB');
      livekit.remote[bob.identity] = bob;
      call.onParticipantConnected(
          lk.ParticipantConnectedEvent(participant: bob));
      await pumpEventQueue();
      expect(changes, hasLength(1));
      expect(call.connectedUserIds, contains('@bob:example.org'));

      livekit.remote.remove(bob.identity);
      call.onParticipantDisconnected(
          lk.ParticipantDisconnectedEvent(participant: bob));
      await pumpEventQueue();
      expect(changes, hasLength(2));
      expect(call.connectedUserIds, {_me});
    });

    test('nobody, once the call has ended', () async {
      joined(serverTime);
      final call = await join();
      call.state = VoipState.ended;

      expect(call.connectedUserIds, isEmpty);
    });
  });
}
