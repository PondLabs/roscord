import 'dart:async';

import 'package:commet/browser_runtime.dart';
import 'package:commet/client/components/video_embed/media_embed_adapter.dart';
import 'package:commet/client/components/video_embed/video_playback_source.dart';
import 'package:test/test.dart';

OfficialVideoEmbedSource _youtubeSource() => OfficialVideoEmbedSource(
      Uri.https('www.youtube-nocookie.com', '/embed/abc123', const {
        'autoplay': '1',
        'enablejsapi': '1',
        'playsinline': '1',
        'rel': '0',
        'controls': '1',
        'fs': '1',
      }),
      provider: OfficialVideoProvider.youtube,
    );

OfficialVideoEmbedSource _instagramSource() => OfficialVideoEmbedSource(
      Uri.https('www.instagram.com', '/reel/xyz/embed/'),
      provider: OfficialVideoProvider.instagram,
    );

MediaEmbedLaunch _launch({
  OfficialVideoEmbedSource? source,
  bool autoplay = false,
  Uri? loopbackUri,
  PresentationMode presentation = PresentationMode.embedded,
}) {
  return MediaEmbedLaunch(
    source: source ?? _youtubeSource(),
    originalUrl: Uri.parse('https://www.youtube.com/watch?v=abc123'),
    autoplay: autoplay,
    loopbackUri: loopbackUri,
    presentation: presentation,
  );
}

Uri get _loopback => Uri.http('127.0.0.1:4567', '/embed');

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('wrapper contract (loopback origin, Referer, media policy)', () {
    test('youtube forces autoplay=1 only when autoplay is requested', () {
      final autoplay = _launch(autoplay: true).playbackUri;
      expect(autoplay.queryParameters['autoplay'], '1');
      expect(autoplay.host, 'www.youtube-nocookie.com');
      expect(autoplay.path, '/embed/abc123');

      final paused = _launch().playbackUri;
      expect(paused, _youtubeSource().uri);
    });

    test('non-youtube providers play their resolved url unchanged', () {
      final instagram = MediaEmbedLaunch(
        source: _instagramSource(),
        originalUrl: Uri.parse('https://www.instagram.com/reel/xyz/'),
        autoplay: true,
      );
      expect(
        instagram.playbackUri.toString(),
        'https://www.instagram.com/reel/xyz/embed/',
      );
    });

    test('page origin preserves the youtube referer behavior', () {
      expect(_launch().pageOrigin, 'https://www.youtube.com');
      final instagram = MediaEmbedLaunch(
        source: _instagramSource(),
        originalUrl: Uri.parse('https://www.instagram.com/reel/xyz/'),
      );
      expect(
        instagram.pageOrigin,
        'https://www.instagram.com',
      );
    });

    test('wrapper html preserves referrer, autoplay, fullscreen, and pip', () {
      final html = _launch(autoplay: true).wrapperHtml;
      expect(
        html,
        contains('<meta name="referrer" '
            'content="strict-origin-when-cross-origin">'),
      );
      expect(
        html,
        contains('referrerpolicy="strict-origin-when-cross-origin"'),
      );
      expect(
        html,
        contains('allow="autoplay; encrypted-media; fullscreen; '
            'picture-in-picture"'),
      );
      expect(html, contains('allowfullscreen'));
      expect(html, contains('background: #000'));
      expect(html, contains('autoplay=1'));
    });

    test('wrapper html escapes the playback url', () {
      // The youtube embed url carries several query parameters; inside the
      // iframe src attribute their separators must be HTML-escaped.
      final html = _launch(autoplay: true).wrapperHtml;
      expect(html, contains('&amp;'));
      expect(html, isNot(contains('?autoplay=1&enablejsapi')));
    });
  });

  group('surface spec (allowlist, loopback, navigation policy)', () {
    test('spec carries the profile, embedded presentation, and loopback', () {
      final spec = _launch(loopbackUri: _loopback).toSurfaceSpec();
      expect(spec.profileKey, ProfileKey(mediaEmbedProfileKey));
      expect(spec.presentation, PresentationMode.embedded);
      expect(spec.privacy, PrivacyMode.persistent);
      expect(spec.initialNavigation.url, _loopback.toString());
      expect(spec.policy.allowExternalNavigation, isTrue);
    });

    test('spec declares the provider allowlist and loopback origin', () {
      final spec = _launch(loopbackUri: _loopback).toSurfaceSpec();
      expect(
        spec.policy.allowedOrigins,
        contains('https://www.youtube-nocookie.com'),
      );
      expect(
        spec.policy.allowedOrigins,
        contains('https://www.youtube.com'),
      );
      expect(
        spec.policy.allowedOrigins,
        contains('https://www.instagram.com'),
      );
      expect(
        spec.policy.allowedLoopbackOrigins,
        ['http://127.0.0.1:4567'],
      );
      expect(spec.policy.allowsUrl(_loopback.toString()), isTrue);
      expect(
        spec.policy.allowsUrl('https://www.youtube-nocookie.com/embed/x'),
        isTrue,
      );
    });

    test('initial navigation without a loopback server is the embed url', () {
      final launch = _launch();
      expect(launch.initialUrl, launch.playbackUri);
      expect(
        launch.toSurfaceSpec().policy.allowedLoopbackOrigins,
        isEmpty,
      );
    });

    test('navigation policy keeps allowlisted urls in process', () {
      final policy = _launch(loopbackUri: _loopback).toSurfaceSpec().policy;
      expect(
        policy.navigationDecision(
          NavigationRequest(url: 'https://www.youtube.com/watch?v=1'),
        ),
        NavigationPolicyDecision.inProcess,
      );
      expect(
        policy.navigationDecision(
          NavigationRequest(url: _loopback.toString()),
        ),
        NavigationPolicyDecision.inProcess,
      );
    });

    test('disallowed links externalize on gesture and cancel otherwise', () {
      final policy = _launch(loopbackUri: _loopback).toSurfaceSpec().policy;
      expect(
        policy.navigationDecision(
          NavigationRequest(
            url: 'https://evil.test/phish',
            userInitiated: true,
          ),
        ),
        NavigationPolicyDecision.external,
      );
      expect(
        policy.navigationDecision(
          NavigationRequest(url: 'https://evil.test/phish'),
        ),
        NavigationPolicyDecision.blocked,
      );
      expect(
        policy.navigationDecision(
          NavigationRequest(
            url: 'https://evil.test/phish',
            disposition: NavigationDisposition.external,
            userInitiated: true,
          ),
        ),
        NavigationPolicyDecision.external,
      );
      expect(
        policy.navigationDecision(
          NavigationRequest(
            url: 'https://evil.test/phish',
            disposition: NavigationDisposition.external,
          ),
        ),
        NavigationPolicyDecision.blocked,
      );
    });

    test('adapter allowlist mirrors the webview suffix rule', () {
      final launch = _launch(loopbackUri: _loopback);
      expect(
        launch.isAllowedNavigation(Uri.parse('https://www.youtube.com/watch')),
        isTrue,
      );
      expect(
        launch.isAllowedNavigation(
          Uri.parse('https://m.youtube-nocookie.com/embed/x'),
        ),
        isTrue,
      );
      expect(
        launch.isAllowedNavigation(
          Uri.parse('https://www.instagram.com/p/x/'),
        ),
        isTrue,
      );
      expect(
        launch.isAllowedNavigation(Uri.parse('http://127.0.0.1:4567/embed')),
        isTrue,
      );
      expect(launch.isAllowedNavigation(Uri.parse('about:blank')), isTrue);
      expect(
        launch.isAllowedNavigation(Uri.parse('https://evil.test/')),
        isFalse,
      );
      expect(
        launch.isAllowedNavigation(
          Uri.parse('https://youtube.com.attacker.test/watch'),
        ),
        isFalse,
      );
    });

    test('spec rejects an initial navigation outside the policy', () {
      expect(
        () => MediaEmbedLaunch(
          source: _youtubeSource(),
          originalUrl: Uri.parse('https://www.youtube.com/watch?v=abc123'),
          loopbackUri: Uri.http('example.com', '/embed'),
        ).toSurfaceSpec(),
        throwsA(
          isA<BrowserRuntimeException>().having(
            (error) => error.code,
            'code',
            BrowserRuntimeErrorCode.invalidSpec,
          ),
        ),
      );
    });
  });

  group('platform routing (desktop cef, web and mobile unchanged)', () {
    test('windows and linux route official video through cef', () {
      expect(
        mediaEmbedUsesCef(isWeb: false, isWindows: true),
        isTrue,
      );
      expect(
        mediaEmbedUsesCef(isWeb: false, isWindows: false, isLinux: true),
        isTrue,
      );
      expect(
        mediaEmbedUsesCef(isWeb: false, isWindows: false),
        isFalse,
      );
      expect(
        mediaEmbedUsesCef(isWeb: true, isWindows: true),
        isFalse,
      );
      expect(
        mediaEmbedUsesCef(isWeb: true, isWindows: false, isLinux: true),
        isFalse,
      );
    });

    test('linux keeps its non-cef path when the cef sandbox cannot start', () {
      // Ubuntu 24.04 restricts unprivileged user namespaces by default; only
      // an installed setuid helper (mode 4755) gets CEF's sandbox past it.
      expect(
        linuxCefSandboxUsable(
          userNamespaceRestriction: '1\n',
          helperMode: 0x1ed,
        ),
        isFalse,
      );
      expect(
        linuxCefSandboxUsable(
          userNamespaceRestriction: '1\n',
          helperMode: 0x9ed,
        ),
        isTrue,
      );
      expect(
        linuxCefSandboxUsable(
          userNamespaceRestriction: '0\n',
          helperMode: 0x1ed,
        ),
        isTrue,
      );
      expect(
        linuxCefSandboxUsable(userNamespaceRestriction: null, helperMode: 0),
        isTrue,
      );
    });

    test('no standalone official-video surface can be declared', () {
      expect(
        () => _launch(presentation: PresentationMode.standalone),
        throwsArgumentError,
      );
      expect(_launch().presentation, PresentationMode.embedded);
    });
  });

  group('session events (external actions vs cancellations)', () {
    test('external outcomes become explicit external actions', () async {
      final runtime = _TestRuntime();
      final session = MediaEmbedSession(
        runtime: runtime,
        launch: _launch(loopbackUri: _loopback),
      );
      await session.open();

      final externals = <Uri>[];
      final subscription = session.externalNavigations.listen(externals.add);
      runtime.emit(
        NavigationEvent(
          session.surfaceId!,
          2,
          const NormalizedNavigation(
            url: 'https://evil.test/phish',
            disposition: NavigationDisposition.current,
            outcome: NavigationOutcome.external,
          ),
        ),
      );
      await _flush();

      expect(externals.map((uri) => uri.toString()), [
        'https://evil.test/phish',
      ]);
      // The embed stays open: externalizing never closes the surface.
      expect(session.isClosed, isFalse);

      await subscription.cancel();
      await session.dispose();
    });

    test('blocked and cancelled outcomes stay in the embed', () async {
      final runtime = _TestRuntime();
      final session = MediaEmbedSession(
        runtime: runtime,
        launch: _launch(loopbackUri: _loopback),
      );
      await session.open();

      final externals = <Uri>[];
      final subscription = session.externalNavigations.listen(externals.add);
      runtime.emit(
        NavigationEvent(
          session.surfaceId!,
          2,
          const NormalizedNavigation(
            url: 'https://evil.test/phish',
            disposition: NavigationDisposition.current,
            outcome: NavigationOutcome.blocked,
          ),
        ),
      );
      runtime.emit(
        NavigationEvent(
          session.surfaceId!,
          3,
          const NormalizedNavigation(
            url: 'https://evil.test/other',
            disposition: NavigationDisposition.external,
            outcome: NavigationOutcome.cancelled,
          ),
        ),
      );
      runtime.emit(
        NavigationEvent(
          session.surfaceId!,
          4,
          const NormalizedNavigation(
            url: 'https://www.youtube.com/watch?v=1',
            disposition: NavigationDisposition.current,
            outcome: NavigationOutcome.allowed,
          ),
        ),
      );
      await _flush();

      expect(externals, isEmpty);

      await subscription.cancel();
      await session.dispose();
    });

    test('popups open in the browser only when the user clicked', () async {
      final runtime = _TestRuntime();
      final session = MediaEmbedSession(
        runtime: runtime,
        launch: _launch(loopbackUri: _loopback),
      );
      await session.open();

      // "Watch on YouTube" is a click; a pop-under opens on its own.
      runtime.emit(
        PopupRequestEvent(
          session.surfaceId!,
          2,
          requestId: 'popup-1-1',
          url: 'https://www.youtube.com/watch?v=abc123',
          userGesture: true,
        ),
      );
      runtime.emit(
        PopupRequestEvent(
          session.surfaceId!,
          3,
          requestId: 'popup-1-2',
          url: 'https://ads.example/landing',
          userGesture: false,
        ),
      );
      await _flush();

      expect(
        runtime.commands
            .whereType<PopupCommand>()
            .map((command) => (command.requestId, command.action)),
        [
          ('popup-1-1', PopupAction.openExternal),
          ('popup-1-2', PopupAction.deny),
        ],
      );

      await session.dispose();
    });

    test('failed surfaces before ready surface a retryable error', () async {
      final runtime = _TestRuntime()..autoReady = false;
      final session = MediaEmbedSession(
        runtime: runtime,
        launch: _launch(loopbackUri: _loopback),
      );

      final opening = session.open();
      runtime.emit(
        const FailedEvent(
          SurfaceId(1),
          1,
          SurfaceFailure(FailureKind.runtimeLost, 'host stopped'),
        ),
      );

      await expectLater(opening, throwsA(isA<StateError>()));
      await session.dispose();
    });
  });

  group('lifecycle (no profile, host, or window leak)', () {
    test('closing playback closes the runtime surface', () async {
      final runtime = _TestRuntime();
      final session = MediaEmbedSession(
        runtime: runtime,
        launch: _launch(loopbackUri: _loopback),
      );
      await session.open();
      final id = session.surfaceId!;

      await session.dispose();

      expect(runtime.closedSurfaceIds, [id]);
      // Disposing twice is safe.
      await session.dispose();
      expect(runtime.closedSurfaceIds, [id]);
    });

    test('events after dispose produce no callbacks', () async {
      final runtime = _TestRuntime();
      final session = MediaEmbedSession(
        runtime: runtime,
        launch: _launch(loopbackUri: _loopback),
      );
      await session.open();

      final externals = <Uri>[];
      final subscription = session.externalNavigations.listen(externals.add);
      await session.dispose();
      runtime.emit(
        NavigationEvent(
          session.surfaceId ?? const SurfaceId(1),
          9,
          const NormalizedNavigation(
            url: 'https://evil.test/phish',
            disposition: NavigationDisposition.current,
            outcome: NavigationOutcome.external,
          ),
        ),
      );
      await _flush();

      expect(externals, isEmpty);
      await subscription.cancel();
    });

    test('opening a session disposes the previous session first', () async {
      final runtime = _TestRuntime();
      final adapter = MediaEmbedAdapter(runtime: runtime);
      final first = await adapter.openSession(_launch(loopbackUri: _loopback));
      final second = await adapter.openSession(
        _launch(loopbackUri: Uri.http('127.0.0.1:7654', '/embed')),
      );

      expect(runtime.closedSurfaceIds, [first.surfaceId]);
      expect(adapter.activeSession, same(second));

      await adapter.dispose();
      expect(adapter.activeSession, isNull);
    });

    test('concurrent opens serialize and leave one active session', () async {
      final runtime = _TestRuntime();
      final adapter = MediaEmbedAdapter(runtime: runtime);

      final sessions = await Future.wait([
        adapter.openSession(_launch(loopbackUri: _loopback)),
        adapter.openSession(
          _launch(loopbackUri: Uri.http('127.0.0.1:7654', '/embed')),
        ),
      ]);

      expect(runtime.closedSurfaceIds, [sessions.first.surfaceId]);
      expect(adapter.activeSession, same(sessions.last));
      expect(runtime.openedSpecs, hasLength(2));

      await adapter.dispose();
    });

    test('open failure closes nothing and stays retryable', () async {
      final runtime = _TestRuntime()..failNextOpen = true;
      final adapter = MediaEmbedAdapter(runtime: runtime);

      await expectLater(
        adapter.openSession(_launch(loopbackUri: _loopback)),
        throwsA(isA<Object>()),
      );
      expect(adapter.activeSession, isNull);

      final session = await adapter.openSession(
        _launch(loopbackUri: _loopback),
      );
      expect(adapter.activeSession, same(session));
      await adapter.dispose();
    });
  });
}

class _TestRuntime implements BrowserRuntime {
  final StreamController<SurfaceEvent> _events =
      StreamController<SurfaceEvent>.broadcast();
  final List<SurfaceSpec> openedSpecs = [];
  final List<SurfaceCommand> commands = [];
  final List<SurfaceId> closedSurfaceIds = [];
  bool failNextOpen = false;
  bool autoReady = true;
  int _nextSurfaceId = 1;

  @override
  Stream<SurfaceEvent> events() => _events.stream;

  @override
  Future<SurfaceId> open(SurfaceSpec spec) async {
    openedSpecs.add(spec);
    if (failNextOpen) {
      failNextOpen = false;
      throw StateError('simulated open failure');
    }
    final id = SurfaceId(_nextSurfaceId++);
    if (autoReady) {
      Future<void>.delayed(
        Duration.zero,
        () => _events.add(ReadyEvent(id, 1, spec.initialNavigation)),
      );
    }
    return id;
  }

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) async {
    commands.add(command);
  }

  @override
  Future<void> close(SurfaceId surfaceId) async {
    closedSurfaceIds.add(surfaceId);
    _events.add(ClosedEvent(surfaceId, 1, CloseReason.user));
  }

  void emit(SurfaceEvent event) => _events.add(event);
}
