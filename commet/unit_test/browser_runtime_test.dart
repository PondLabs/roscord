import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

SurfaceSpec _spec({PrivacyMode privacy = PrivacyMode.persistent}) {
  return SurfaceSpec(
    profileKey: ProfileKey('account-a'),
    presentation: PresentationMode.embedded,
    privacy: privacy,
    initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
    policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
  );
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  test('fake host completes lifecycle and coalesces only frames', () async {
    final runtime = FakeBrowserRuntime();
    final events = <SurfaceEvent>[];
    final subscription = runtime.events().listen(events.add);
    final surface = await runtime.open(_spec());
    await _flushEvents();

    expect(events, hasLength(1));
    expect(events.single, isA<ReadyEvent>());
    events.clear();

    runtime.publishFrame(
      surface,
      FrameReference(
        slot: 0,
        width: 10,
        height: 10,
        stride: 40,
        format: PixelFormat.bgraPremultiplied,
        sequence: 1,
      ),
    );
    final focus = runtime.command(
      surface,
      FocusCommand(sequence: 1, focused: true),
    );
    runtime.publishFrame(
      surface,
      FrameReference(
        slot: 0,
        width: 10,
        height: 10,
        stride: 40,
        format: PixelFormat.bgraPremultiplied,
        sequence: 2,
      ),
    );
    await focus;
    await _flushEvents();

    expect(events, hasLength(2));
    expect(events.first, isA<WindowChangedEvent>());
    expect((events.last as FrameReadyEvent).frame.sequence, 2);

    events.clear();
    await runtime.close(surface);
    await _flushEvents();
    expect(events.single, isA<ClosedEvent>());
    await expectLater(
      runtime.close(surface),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.staleSurface,
        ),
      ),
    );
    await subscription.cancel();
  });

  test('enforces profile and command sequence ownership', () async {
    final runtime = FakeBrowserRuntime();
    final surface = await runtime.open(_spec());
    runtime.events();

    await expectLater(
      runtime.command(
        surface,
        FocusCommand(
          sequence: 1,
          profileKey: ProfileKey('account-b'),
          focused: true,
        ),
      ),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.profileMismatch,
        ),
      ),
    );

    await runtime.command(surface, FocusCommand(sequence: 1, focused: true));
    await expectLater(
      runtime.command(surface, FocusCommand(sequence: 1, focused: false)),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.sequenceViolation,
        ),
      ),
    );
  });

  test('enforces navigation policy and normalizes external routing', () async {
    final runtime = FakeBrowserRuntime();
    final events = <SurfaceEvent>[];
    final subscription = runtime.events().listen(events.add);
    final surface = await runtime.open(
      SurfaceSpec(
        profileKey: ProfileKey('account-a'),
        presentation: PresentationMode.embedded,
        privacy: PrivacyMode.persistent,
        initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
        policy: SurfacePolicy(
          allowedOrigins: ['https://widget.test'],
          allowedLoopbackOrigins: [
            'http://127.0.0.1:43123',
            'http://[::1]:43123',
          ],
          allowExternalNavigation: true,
        ),
      ),
    );
    await _flushEvents();
    events.clear();

    await runtime.command(
      surface,
      NavigateCommand(
        sequence: 1,
        navigation: NavigationRequest(url: 'https://widget.test/path'),
      ),
    );
    await runtime.command(
      surface,
      NavigateCommand(
        sequence: 2,
        navigation: NavigationRequest(
          url: 'https://sso.example/login',
          disposition: NavigationDisposition.external,
          userInitiated: true,
        ),
      ),
    );
    await runtime.command(
      surface,
      NavigateCommand(
        sequence: 3,
        navigation: NavigationRequest(url: 'https://evil.example/redirect'),
      ),
    );
    await runtime.command(
      surface,
      NavigateCommand(
        sequence: 4,
        navigation: NavigationRequest(
          url: 'https://sso.example/login',
          userInitiated: true,
        ),
      ),
    );
    await _flushEvents();

    expect(events, hasLength(4));
    expect(
      (events[0] as NavigationEvent).navigation.outcome,
      NavigationOutcome.allowed,
    );
    expect(
      (events[1] as NavigationEvent).navigation.outcome,
      NavigationOutcome.external,
    );
    expect(
      (events[2] as NavigationEvent).navigation.outcome,
      NavigationOutcome.blocked,
    );
    expect(
      (events[3] as NavigationEvent).navigation.outcome,
      NavigationOutcome.external,
    );
    await subscription.cancel();
  });

  test('rejects unsafe URLs and undeclared policy origins', () {
    expect(
      () => NavigationRequest(url: 'file:///C:/secret'),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.invalidSpec,
        ),
      ),
    );
    expect(
      () => NavigationRequest(url: 'https://widget.test:'),
      throwsA(isA<BrowserRuntimeException>()),
    );
    expect(
      () => SurfacePolicy(allowedOrigins: ['http://widget.test']),
      throwsA(isA<BrowserRuntimeException>()),
    );
    expect(
      () => SurfacePolicy(allowedLoopbackOrigins: ['http://127.0.0.1']),
      throwsA(isA<BrowserRuntimeException>()),
    );
    expect(
      SurfacePolicy().allowsUrl('commet://fixture'),
      isTrue,
    );
    expect(
      SurfacePolicy().allowsUrl('commet://fixture?redirect=https://evil'),
      isFalse,
    );
  });

  test('round-trips popup request user gesture metadata', () {
    final event = SurfaceEvent.fromJson({
      'type': 'popup_request',
      'payload': {
        'surface_id': 4,
        'sequence': 2,
        'request_id': 'popup-4-1',
        'url': 'https://sso.example/login',
        'user_gesture': true,
      },
    });
    expect(event, isA<PopupRequestEvent>());
    expect((event as PopupRequestEvent).userGesture, isTrue);
    expect(event.toJson()['payload'], containsPair('user_gesture', true));
  });

  test('round-trips frame ring names, pointer modifiers, and cursors', () {
    final event = SurfaceEvent.fromJson({
      'type': 'frame_ready',
      'payload': {
        'surface_id': 3,
        'sequence': 4,
        'frame': {
          'slot': 1,
          'width': 640,
          'height': 360,
          'stride': 2560,
          'format': 'rgba_premultiplied',
          'sequence': 9,
          'buffer': 'roscord-cef-10-ab-3-1',
        },
      },
    }) as FrameReadyEvent;
    expect(event.frame.buffer, 'roscord-cef-10-ab-3-1');
    expect(event.frame.format, PixelFormat.rgbaPremultiplied);
    expect(
      event.frame.toJson(),
      containsPair('buffer', 'roscord-cef-10-ab-3-1'),
    );
    // Fixture frames have no ring behind them.
    final fixture = FrameReference(
      slot: 0,
      width: 2,
      height: 2,
      stride: 8,
      format: PixelFormat.bgraPremultiplied,
      sequence: 1,
    );
    expect(fixture.toJson().containsKey('buffer'), isFalse);
    expect(FrameReference.fromJson(fixture.toJson()).buffer, isNull);
    expect(
      () => FrameReference.fromJson({...fixture.toJson(), 'buffer': 7}),
      throwsA(isA<ProtocolException>()),
    );

    final pointer = InputEvent.fromJson(
      InputEvent.pointer(
        kind: PointerKind.down,
        x: 1,
        y: 2,
        buttons: 1,
        modifiers: InputModifiers.shift | InputModifiers.control,
      ).toJson(),
    ) as PointerInput;
    expect(pointer.modifiers, InputModifiers.shift | InputModifiers.control);
    // Senders that predate modifiers omit them.
    final plain = InputEvent.fromJson({
      'type': 'pointer',
      'payload': {'kind': 'move', 'x': 1, 'y': 2},
    }) as PointerInput;
    expect(plain.modifiers, 0);

    final cursor = SurfaceEvent.fromJson({
      'type': 'cursor_changed',
      'payload': {'surface_id': 3, 'sequence': 5, 'cursor': 'pointer'},
    });
    expect(cursor, isA<CursorChangedEvent>());
    expect((cursor as CursorChangedEvent).cursor, 'pointer');
    expect(cursor.toJson()['payload'], containsPair('cursor', 'pointer'));
  });

  test(
    'round-trips recursive binary script values and immutable policy data',
    () {
      final envelope = ScriptEnvelope(
        source: ScriptSource.page,
        origin: 'https://widget.test',
        channel: 'widget',
        requestId: 'request-1',
        value: {
          'nested': [
            Uint8List.fromList([1, 2, 3]),
            {
              'deep': BrowserRuntimeBlob(Uint8List.fromList([4, 5])),
            },
          ],
        },
      );
      final decoded = ScriptEnvelope.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(envelope.toJson())) as Map,
        ),
      );
      final nested = decoded.value as Map;
      final values = nested['nested']! as List<dynamic>;
      expect(values[0], orderedEquals([1, 2, 3]));
      expect(values[1], isA<Map>());
      final blob = (values[1] as Map)['deep'] as BrowserRuntimeBlob;
      expect(blob.bytes, orderedEquals([4, 5]));

      final privateSpec = _spec(privacy: PrivacyMode.privateContext);
      expect(privateSpec.toJson()['privacy'], 'private');
      expect(
        SurfaceSpec.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(privateSpec.toJson())) as Map,
          ),
        ).privacy,
        PrivacyMode.privateContext,
      );
    },
  );

  test('rejects malformed, oversized, and unknown framed messages', () {
    final codec = FramedCodec('nonce', maxFrameBytes: 256);
    final encoded = codec.encode(const AckWireMessage(1));
    expect(codec.decode(encoded), isA<AckWireMessage>());
    expect(codec.decodeNext(encoded.sublist(0, encoded.length - 1)), isNull);

    final malformedBody = utf8.encode('{"version":1,"nonce":"nonce"');
    final malformed = _frame(malformedBody);
    expect(() => codec.decode(malformed), throwsA(isA<ProtocolException>()));

    final unknownBody = utf8.encode(
      jsonEncode({
        'version': browserRuntimeProtocolVersion,
        'nonce': 'nonce',
        'message': {'type': 'future', 'payload': {}},
      }),
    );
    expect(
      () => codec.decode(_frame(unknownBody)),
      throwsA(
        isA<ProtocolException>().having(
          (error) => error.code,
          'code',
          'unknown_message_type',
        ),
      ),
    );

    final oversized = Uint8List(4 + 257);
    ByteData.sublistView(oversized).setUint32(0, 257, Endian.big);
    expect(
      () => codec.decode(oversized),
      throwsA(
        isA<ProtocolException>().having(
          (error) => error.code,
          'code',
          'frame_too_large',
        ),
      ),
    );
  });

  test('round-trips transport heartbeat messages', () {
    final codec = FramedCodec('nonce');
    final heartbeat = codec.encode(const HeartbeatWireMessage(7));
    expect(
      codec.decode(heartbeat),
      isA<HeartbeatWireMessage>()
          .having((message) => message.requestId, 'id', 7),
    );
    final acknowledgement = codec.encode(const HeartbeatAckWireMessage(7));
    expect(
      codec.decode(acknowledgement),
      isA<HeartbeatAckWireMessage>()
          .having((message) => message.requestId, 'id', 7),
    );
  });

  test('classifies media capabilities exactly and fails closed', () {
    expect(MediaCapability.classify('camera'), MediaCapability.camera);
    expect(MediaCapability.classify('microphone'), MediaCapability.microphone);
    expect(
      MediaCapability.classify('display_video'),
      MediaCapability.displayVideo,
    );
    expect(
      MediaCapability.classify('display_audio'),
      MediaCapability.displayAudio,
    );
    for (final foreign in [
      'Camera',
      'camera ',
      ' screen',
      'geolocation',
      '',
      'display',
    ]) {
      expect(MediaCapability.classify(foreign), MediaCapability.unknown);
    }
    expect(MediaCapability.camera.supportsPersistentGrant, isTrue);
    expect(MediaCapability.microphone.supportsPersistentGrant, isTrue);
    expect(MediaCapability.displayVideo.supportsPersistentGrant, isFalse);
    expect(MediaCapability.displayAudio.supportsPersistentGrant, isFalse);
    expect(MediaCapability.unknown.supportsPersistentGrant, isFalse);
    expect(MediaCapability.displayVideo.isDisplay, isTrue);
    expect(MediaCapability.camera.isDisplay, isFalse);
    expect(
      () => MediaGrantScope(
        profileKey: ProfileKey('account-a'),
        requestingOrigin: 'https://widget.test',
        topLevelOrigin: 'https://shell.test',
        capability: MediaCapability.unknown,
      ),
      throwsA(isA<BrowserRuntimeException>()),
    );
  });

  test('media grants support deny, once, session, and scoped persistence', () {
    final store = MediaGrantStore();
    final scope = MediaGrantScope(
      profileKey: ProfileKey('account-a'),
      requestingOrigin: 'https://widget.test',
      topLevelOrigin: 'https://shell.test',
      capability: MediaCapability.camera,
    );
    const policyOrigins = ['https://widget.test', 'https://shell.test'];

    bool covers() => store.takeGrant(
          scope,
          policyOrigins: policyOrigins,
          capabilityAllowed: true,
          osMediated: true,
          privateContext: false,
        );

    // Deny-by-default.
    expect(covers(), isFalse);

    // Once applies to the pending request only.
    expect(
      store.remember(scope, PermissionDecision.allowOnce,
          privateContext: false),
      isFalse,
    );
    expect(store.length, 0);
    expect(covers(), isFalse);

    // Session grants apply while the session lives.
    expect(
      store.remember(scope, PermissionDecision.allowSession,
          privateContext: false),
      isTrue,
    );
    expect(covers(), isTrue);

    // An explicit deny revokes the stored grant.
    expect(
      store.remember(scope, PermissionDecision.deny, privateContext: false),
      isFalse,
    );
    expect(covers(), isFalse);

    // Persistent grants apply across surfaces of the same scope.
    expect(
      store.remember(scope, PermissionDecision.allowAlways,
          privateContext: false),
      isTrue,
    );
    expect(covers(), isTrue);
  });

  test('media grants are scoped and rechecked on every use', () {
    final store = MediaGrantStore();
    final scope = MediaGrantScope(
      profileKey: ProfileKey('account-a'),
      requestingOrigin: 'https://widget.test',
      topLevelOrigin: 'https://shell.test',
      capability: MediaCapability.camera,
    );
    store.remember(scope, PermissionDecision.allowAlways,
        privateContext: false);
    const policyOrigins = ['https://widget.test', 'https://shell.test'];

    MediaGrantScope other({
      String account = 'account-a',
      String requesting = 'https://widget.test',
      String top = 'https://shell.test',
      MediaCapability capability = MediaCapability.camera,
    }) =>
        MediaGrantScope(
          profileKey: ProfileKey(account),
          requestingOrigin: requesting,
          topLevelOrigin: top,
          capability: capability,
        );

    bool coversScope(MediaGrantScope candidate,
            {List<String> origins = policyOrigins,
            bool capabilityAllowed = true,
            bool osMediated = true,
            bool privateContext = false}) =>
        store.takeGrant(
          candidate,
          policyOrigins: origins,
          capabilityAllowed: capabilityAllowed,
          osMediated: osMediated,
          privateContext: privateContext,
        );

    // A different account, requesting origin, top-level origin, or
    // capability must not inherit the grant.
    expect(coversScope(other(account: 'account-b')), isFalse);
    expect(
      coversScope(other(requesting: 'https://evil.test'),
          origins: ['https://evil.test', 'https://shell.test']),
      isFalse,
    );
    expect(
      coversScope(other(top: 'https://other.test'),
          origins: ['https://widget.test', 'https://other.test']),
      isFalse,
    );
    expect(coversScope(other(capability: MediaCapability.microphone)), isFalse);

    // Every use rechecks current policy and OS mediation.
    expect(coversScope(scope), isTrue);
    expect(coversScope(scope, origins: ['https://shell.test']), isFalse);
    expect(coversScope(scope, capabilityAllowed: false), isFalse);
    expect(coversScope(scope, osMediated: false), isFalse);
  });

  test('display capture always needs fresh consent', () {
    final store = MediaGrantStore();
    const policyOrigins = ['https://widget.test', 'https://shell.test'];
    for (final capability in [
      MediaCapability.displayVideo,
      MediaCapability.displayAudio,
      MediaCapability.displayVideoAndAudio,
    ]) {
      final scope = MediaGrantScope(
        profileKey: ProfileKey('account-a'),
        requestingOrigin: 'https://widget.test',
        topLevelOrigin: 'https://shell.test',
        capability: capability,
      );
      // Even allowAlways stores nothing for display capture.
      expect(
        store.remember(scope, PermissionDecision.allowAlways,
            privateContext: false),
        isFalse,
      );
      expect(
        store.takeGrant(
          scope,
          policyOrigins: policyOrigins,
          capabilityAllowed: true,
          osMediated: true,
          privateContext: false,
        ),
        isFalse,
      );
    }
  });

  test('private contexts never hold persistent media grants', () {
    final store = MediaGrantStore();
    final scope = MediaGrantScope(
      profileKey: ProfileKey('account-a'),
      requestingOrigin: 'https://widget.test',
      topLevelOrigin: 'https://shell.test',
      capability: MediaCapability.camera,
    );
    const policyOrigins = ['https://widget.test', 'https://shell.test'];
    expect(
      store.remember(scope, PermissionDecision.allowAlways,
          privateContext: true),
      isTrue,
    );
    // The session grant applies while the session lives ...
    expect(
      store.takeGrant(
        scope,
        policyOrigins: policyOrigins,
        capabilityAllowed: true,
        osMediated: true,
        privateContext: true,
      ),
      isTrue,
    );
    // ... but evaporates with the session and is not persistent.
    store.clearSession();
    expect(
      store.takeGrant(
        scope,
        policyOrigins: policyOrigins,
        capabilityAllowed: true,
        osMediated: true,
        privateContext: true,
      ),
      isFalse,
    );

    store.remember(scope, PermissionDecision.allowAlways,
        privateContext: false);
    store.clearProfile(ProfileKey('account-a'));
    expect(store.length, 0);
  });

  test('portal outcomes deny the page with sanitized events', () {
    for (final outcome in [
      CapturePortalOutcome.denied,
      CapturePortalOutcome.dismissed,
      CapturePortalOutcome.timedOut,
      CapturePortalOutcome.disconnected,
      CapturePortalOutcome.unsupported,
    ]) {
      expect(outcome.deniesPage, isTrue);
      final message = outcome.sanitizedMessage;
      expect(message, isNotEmpty);
      expect(message.toLowerCase(), isNot(contains('https://')));
      expect(message.toLowerCase(), isNot(contains('token')));
      expect(message, isNot(contains('/')));
    }
    expect(CapturePortalOutcome.parse('granted'), CapturePortalOutcome.granted);
    expect(CapturePortalOutcome.granted.deniesPage, isFalse);
    expect(CapturePortalOutcome.parse('bogus'), isNull);
    expect(
      sanitizedPermissionDeniedMessage(MediaCapability.displayVideo),
      contains('fresh consent'),
    );
  });

  MediaPolicyView policyView({bool privateContext = false}) {
    return MediaPolicyView(
      origins: const ['https://widget.test', 'https://shell.test'],
      capabilityAllowed: true,
      privateContext: privateContext,
      osMediated: true,
    );
  }

  SurfaceId registerCamera(HostPermissionRegistry registry, String request) {
    final surface = SurfaceId(1);
    expect(
      registry.register(
        surfaceId: surface,
        profileKey: ProfileKey('account-a'),
        requestId: request,
        requestingOrigin: 'https://widget.test',
        topLevelOrigin: 'https://shell.test',
        capabilityName: 'camera',
      ),
      MediaCapability.camera,
    );
    return surface;
  }

  test('permission registry rejects replays and unknown requests', () {
    final registry = HostPermissionRegistry(portalMediationRequired: false);
    registerCamera(registry, 'media-1');
    expect(
      () => registerCamera(registry, 'media-1'),
      throwsA(isA<BrowserRuntimeException>()),
    );
    expect(
      () => registry.resolve(
          'media-missing', PermissionDecision.allowAlways, policyView()),
      throwsA(isA<BrowserRuntimeException>()),
    );
    expect(registry.pendingCount, 1);
  });

  test('permission registry denies unknown capabilities with a failure', () {
    final registry = HostPermissionRegistry(portalMediationRequired: false);
    expect(
      registry.register(
        surfaceId: const SurfaceId(2),
        profileKey: ProfileKey('account-a'),
        requestId: 'media-foreign',
        requestingOrigin: 'https://widget.test',
        topLevelOrigin: 'https://shell.test',
        capabilityName: 'geolocation',
      ),
      MediaCapability.unknown,
    );
    final resolution = registry.resolve(
        'media-foreign', PermissionDecision.allowAlways, policyView());
    expect(resolution.grantedOnce, isFalse);
    expect(resolution.stored, isFalse);
    expect(resolution.failure!.kind, FailureKind.permissionDenied);
    expect(resolution.failure!.message, isNot(contains('https://')));
  });

  test('permission registry auto-covers session grants', () {
    final registry = HostPermissionRegistry(portalMediationRequired: false);
    registerCamera(registry, 'media-1');
    final first = registry.resolve(
        'media-1', PermissionDecision.allowSession, policyView());
    expect(first.grantedOnce, isTrue);
    expect(first.stored, isTrue);
    expect(first.failure, isNull);

    registerCamera(registry, 'media-2');
    expect(
      registry.storedGrantCovers(
        surfaceId: const SurfaceId(1),
        profileKey: ProfileKey('account-a'),
        requestingOrigin: 'https://widget.test',
        topLevelOrigin: 'https://shell.test',
        capabilityName: 'camera',
        policy: policyView(),
      ),
      isTrue,
    );
  });

  test('permission registry mediates display capture through the portal', () {
    final registry = HostPermissionRegistry(portalMediationRequired: true);
    registry.register(
      surfaceId: const SurfaceId(1),
      profileKey: ProfileKey('account-a'),
      requestId: 'media-display-1',
      requestingOrigin: 'https://widget.test',
      topLevelOrigin: 'https://shell.test',
      capabilityName: 'display_video',
    );
    // Stored grants never cover display capture ...
    expect(
      registry.storedGrantCovers(
        surfaceId: const SurfaceId(1),
        profileKey: ProfileKey('account-a'),
        requestingOrigin: 'https://widget.test',
        topLevelOrigin: 'https://shell.test',
        capabilityName: 'display_video',
        policy: policyView(),
      ),
      isFalse,
    );
    // ... and without the portal grant the app decision cannot proceed.
    final blocked = registry.resolve(
        'media-display-1', PermissionDecision.allowOnce, policyView());
    expect(blocked.grantedOnce, isFalse);
    expect(blocked.failure!.kind, FailureKind.captureDenied);

    registry.register(
      surfaceId: const SurfaceId(1),
      profileKey: ProfileKey('account-a'),
      requestId: 'media-display-2',
      requestingOrigin: 'https://widget.test',
      topLevelOrigin: 'https://shell.test',
      capabilityName: 'display_video',
    );
    final (surface, portalFailure) = registry.reportPortalOutcome(
        'media-display-2', CapturePortalOutcome.granted);
    expect(surface, const SurfaceId(1));
    expect(portalFailure, isNull);
    final granted = registry.resolve(
        'media-display-2', PermissionDecision.allowAlways, policyView());
    expect(granted.grantedOnce, isTrue);
    expect(granted.stored, isFalse);
    expect(granted.failure, isNull);
  });

  test('permission registry reports every portal failure sanitized', () {
    for (final outcome in [
      CapturePortalOutcome.denied,
      CapturePortalOutcome.dismissed,
      CapturePortalOutcome.timedOut,
      CapturePortalOutcome.disconnected,
      CapturePortalOutcome.unsupported,
    ]) {
      final registry = HostPermissionRegistry(portalMediationRequired: true);
      registry.register(
        surfaceId: const SurfaceId(3),
        profileKey: ProfileKey('account-a'),
        requestId: 'media-display',
        requestingOrigin: 'https://widget.test',
        topLevelOrigin: 'https://shell.test',
        capabilityName: 'display_video',
      );
      final (surface, failure) =
          registry.reportPortalOutcome('media-display', outcome);
      expect(surface, const SurfaceId(3));
      expect(failure!.kind, FailureKind.captureDenied);
      expect(failure.message, outcome.sanitizedMessage);
      expect(
        () => registry.resolve(
            'media-display', PermissionDecision.allowOnce, policyView()),
        throwsA(isA<BrowserRuntimeException>()),
      );
    }
  });

  test('permission registry drops pending requests with the surface', () {
    final registry = HostPermissionRegistry(portalMediationRequired: false);
    registerCamera(registry, 'media-1');
    registry.removeSurface(const SurfaceId(1));
    expect(registry.pendingCount, 0);
    expect(
      () => registry.resolve(
          'media-1', PermissionDecision.allowOnce, policyView()),
      throwsA(isA<BrowserRuntimeException>()),
    );
  });

  test('permission_denied and capture_denied round-trip on the wire', () {
    for (final kind in [
      FailureKind.permissionDenied,
      FailureKind.captureDenied,
    ]) {
      final failure = SurfaceFailure(kind, 'sanitized');
      final decoded = SurfaceFailure.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(failure.toJson())) as Map,
        ),
      );
      expect(decoded.kind, kind);
    }
  });
}

Uint8List _frame(List<int> body) {
  final frame = Uint8List(body.length + 4);
  ByteData.sublistView(frame).setUint32(0, body.length, Endian.big);
  frame.setRange(4, frame.length, body);
  return frame;
}
