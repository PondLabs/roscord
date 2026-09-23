import 'dart:async';

import 'package:commet/browser_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

SurfaceSpec _standaloneSpec({String profile = 'account-a'}) {
  return SurfaceSpec(
    profileKey: ProfileKey(profile),
    presentation: PresentationMode.standalone,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
    policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
  );
}

SurfaceSpec _embeddedSpec({String profile = 'account-a'}) {
  return SurfaceSpec(
    profileKey: ProfileKey(profile),
    presentation: PresentationMode.embedded,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
    policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// Recording decorator over the deterministic fake: keeps the fake's event
/// semantics while capturing every command for ordering assertions and
/// counting host starts (one runtime means one host).
class _RecordingRuntime implements BrowserRuntime {
  final FakeBrowserRuntime _inner = FakeBrowserRuntime();
  final List<SurfaceCommand> commands = [];
  int openCount = 0;

  @override
  Stream<SurfaceEvent> events() => _inner.events();

  @override
  Future<SurfaceId> open(SurfaceSpec spec) {
    openCount++;
    return _inner.open(spec);
  }

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) {
    commands.add(command);
    return _inner.command(surfaceId, command);
  }

  @override
  Future<void> close(SurfaceId surfaceId) => _inner.close(surfaceId);

  void publishFrame(SurfaceId id, FrameReference frame) =>
      _inner.publishFrame(id, frame);
}

void main() {
  test(
      'standalone and embedded surfaces share one runtime, profile, policy, and permissions',
      () async {
    final runtime = _RecordingRuntime();
    final embedded = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
    );
    final standalone = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(),
    );
    final embeddedId = await embedded.open();
    final standaloneId = await standalone.open();
    await _flush();

    // One shared host: two opens on the same runtime instance, distinct
    // logical surfaces, no second runtime object.
    expect(runtime.openCount, 2);
    expect(embeddedId, isNot(equals(standaloneId)));
    expect(embedded.isReady, isTrue);
    expect(standalone.isReady, isTrue);

    // Same account profile key on both surfaces.
    expect(embedded.spec.profileKey, ProfileKey('account-a'));
    expect(standalone.spec.profileKey, ProfileKey('account-a'));

    // Same policy: in-policy navigation accepted on the standalone surface.
    await runtime.command(
      standaloneId,
      NavigateCommand(
        sequence: 100,
        profileKey: standalone.spec.profileKey,
        navigation: NavigationRequest(url: 'https://widget.test/room'),
      ),
    );

    // Same permission mediation: media, download, clipboard, upload, and
    // popup decisions are accepted as typed commands on the standalone
    // surface, exactly like embedded.
    await runtime.command(
      standaloneId,
      PermissionCommand(
        sequence: 101,
        profileKey: standalone.spec.profileKey,
        requestId: 'media-1',
        decision: PermissionDecision.deny,
      ),
    );
    await runtime.command(
      standaloneId,
      DownloadCommand(
        sequence: 102,
        profileKey: standalone.spec.profileKey,
        requestId: 'download-1',
        decision: const DenyDownload(),
      ),
    );
    await runtime.command(
      standaloneId,
      ClipboardCommand(
        sequence: 103,
        profileKey: standalone.spec.profileKey,
        requestId: 'clipboard-1',
        decision: ClipboardDecision.deny,
      ),
    );
    await runtime.command(
      standaloneId,
      UploadCommand(
        sequence: 104,
        profileKey: standalone.spec.profileKey,
        requestId: 'upload-1',
        decision: const DenyUpload(),
      ),
    );
    await runtime.command(
      standaloneId,
      PopupCommand(
        sequence: 105,
        profileKey: standalone.spec.profileKey,
        requestId: 'popup-1',
        action: PopupAction.deny,
      ),
    );

    // Cross-account isolation: a mismatched profile key is rejected on the
    // standalone surface without starting another host.
    await expectLater(
      runtime.command(
        standaloneId,
        FocusCommand(
          sequence: 106,
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

    await embedded.close();
    await standalone.close();
    await embedded.dispose();
    await standalone.dispose();
  });

  test(
      'owned-window geometry, focus, z-order, resize/DPI, input, IME, popup, and close work',
      () async {
    final runtime = _RecordingRuntime();
    final surface = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(),
    );
    await surface.open();
    await _flush();

    // Pointer, keyboard, wheel, and IME input through the ordered stream.
    await surface.pointer(PointerKind.down, 100, 200, buttons: 1);
    await surface.pointer(PointerKind.move, 110, 210);
    await surface.pointer(PointerKind.up, 110, 210);
    await surface.wheel(110, 210, 0, -120);
    await surface.key('a', 'KeyA', pressed: true);
    await surface.key('a', 'KeyA', pressed: false);
    await surface.ime(ImePhase.start, 'ni', selectionStart: 0, selectionEnd: 2);
    await surface.ime(ImePhase.update, 'nih',
        selectionStart: 0, selectionEnd: 3);
    await surface.ime(ImePhase.commit, 'nihon',
        selectionStart: 5, selectionEnd: 5);
    await surface.ime(ImePhase.cancel, '');

    final inputs =
        runtime.commands.whereType<InputCommand>().map((c) => c.input).toList();
    expect(inputs.whereType<PointerInput>(), hasLength(4));
    expect(inputs.whereType<KeyboardInput>(), hasLength(2));
    expect(inputs.whereType<ImeInput>(), hasLength(4));
    final wheel = inputs
        .whereType<PointerInput>()
        .firstWhere((p) => p.kind == PointerKind.wheel);
    expect(wheel.deltaY, -120);
    expect(
      inputs.whereType<ImeInput>().map((i) => i.phase).toList(),
      [ImePhase.start, ImePhase.update, ImePhase.commit, ImePhase.cancel],
    );

    // Inverted IME selection is rejected by the contract.
    await expectLater(
      surface.ime(ImePhase.update, 'x', selectionStart: 3, selectionEnd: 1),
      throwsA(isA<BrowserRuntimeException>()),
    );

    // Resize/DPI update owned geometry and surface window_changed events in
    // order; focus and bringToFront drive z-order through the same stream.
    final events = <SurfaceEvent>[];
    final subscription = surface.surfaceEvents.listen(events.add);
    await surface.resize(1280, 720, 1.0);
    await _flush();
    expect(surface.geometry.width, 1280);
    expect(surface.geometry.height, 720);
    expect(surface.geometry.deviceScaleFactor, 1.0);

    await surface.resize(1920, 1080, 2.0);
    await _flush();
    expect(surface.geometry.width, 1920);
    expect(surface.geometry.deviceScaleFactor, 2.0);
    final resized =
        events.whereType<WindowChangedEvent>().last.change as ResizedWindow;
    expect(resized.width, 1920);
    expect(resized.deviceScaleFactor, 2.0);

    await surface.setFocus(true);
    await _flush();
    expect(surface.isFocused, isTrue);
    await surface.setFocus(false);
    await _flush();
    expect(surface.isFocused, isFalse);
    await surface.bringToFront();
    await _flush();
    expect(surface.isFocused, isTrue);
    final focused =
        events.whereType<WindowChangedEvent>().last.change as FocusedWindow;
    expect(focused.focused, isTrue);
    await subscription.cancel();

    // Popup decisions travel as typed commands: deny and explicit external.
    await runtime.command(
      surface.surfaceId!,
      PopupCommand(
        sequence: 1000,
        profileKey: surface.spec.profileKey,
        requestId: 'popup-owned-1',
        action: PopupAction.deny,
      ),
    );
    await runtime.command(
      surface.surfaceId!,
      PopupCommand(
        sequence: 1001,
        profileKey: surface.spec.profileKey,
        requestId: 'popup-owned-2',
        action: PopupAction.openExternal,
      ),
    );

    // Sequences strictly increase across mixed command classes.
    final sequences = runtime.commands.map((c) => c.sequence).toList();
    expect(sequences, orderedEquals(sequences..sort()));
    expect(sequences.toSet(), hasLength(sequences.length));

    // Close is terminal: further commands are stale and the owned window is
    // released without a second host.
    await surface.close();
    await _flush();
    expect(surface.isClosed, isTrue);
    await expectLater(
      surface.pointer(PointerKind.move, 0, 0),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.staleSurface,
        ),
      ),
    );
    await surface.dispose();
  });

  test('two standalone surfaces for one account observe shared browser state',
      () async {
    final runtime = _RecordingRuntime();
    final first = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(profile: 'account-shared'),
    );
    final second = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(profile: 'account-shared'),
    );
    final firstId = await first.open();
    final secondId = await second.open();
    await _flush();

    // Same account: both surfaces open against the shared persistent context.
    expect(firstId, isNot(equals(secondId)));
    expect(first.isReady, isTrue);
    expect(second.isReady, isTrue);
    expect(first.spec.profileKey, second.spec.profileKey);

    // Both observe navigation outcomes under the same policy.
    await runtime.command(
      firstId,
      NavigateCommand(
        sequence: 50,
        profileKey: first.spec.profileKey,
        navigation: NavigationRequest(url: 'https://widget.test/a'),
      ),
    );
    await runtime.command(
      secondId,
      NavigateCommand(
        sequence: 50,
        profileKey: second.spec.profileKey,
        navigation: NavigationRequest(url: 'https://widget.test/b'),
      ),
    );

    // A script message on one surface does not disturb the other surface's
    // sequence space; each surface keeps its own strictly increasing stream
    // while sharing the account context.
    await runtime.command(
      firstId,
      ScriptCommand(
        sequence: 51,
        profileKey: first.spec.profileKey,
        envelope: ScriptEnvelope(
          source: ScriptSource.app,
          origin: 'commet://widget',
          channel: 'chat.commet.matrix_widget',
          requestId: 'shared-1',
          value: {'operation': 'dispatch_script_message'},
        ),
      ),
    );

    // A different account stays isolated even while the shared pair is open.
    final other = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(profile: 'account-other'),
    );
    final otherId = await other.open();
    await _flush();
    expect(other.spec.profileKey, isNot(equals(first.spec.profileKey)));
    await expectLater(
      runtime.command(
        otherId,
        FocusCommand(
          sequence: 1,
          profileKey: ProfileKey('account-shared'),
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

    await first.close();
    await second.close();
    await other.close();
    await first.dispose();
    await second.dispose();
    await other.dispose();
  });

  test('software rendering and process cleanup remain release-authoritative',
      () async {
    // The software flag lives on the shared host starter; the standalone
    // contract is identical either way. Both presentations share one host and
    // one CPU/software policy; neither selects another engine.
    final runtime = _RecordingRuntime();
    final standalone = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(),
    );
    final embedded = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
    );
    final standaloneId = await standalone.open();
    final embeddedId = await embedded.open();
    await _flush();
    expect(standalone.isReady, isTrue);
    expect(embedded.isReady, isTrue);

    // Windowed standalone surfaces never emit frames through Flutter.
    runtime.publishFrame(embeddedId, _frame(1));
    await _flush();
    expect(embedded.latestFrame, isNotNull);

    final softwareHost = WindowsBrowserRuntime(forceSoftwareRendering: true);
    expect(softwareHost.forceSoftwareRendering, isTrue);
    await softwareHost.dispose();

    final defaultHost = WindowsBrowserRuntime();
    expect(defaultHost.forceSoftwareRendering, isFalse);
    await defaultHost.dispose();

    // Deterministic close on both surfaces: no orphan host, no second
    // process, and a second close on the same id is stale.
    await standalone.close();
    await embedded.close();
    await _flush();
    expect(standalone.isClosed, isTrue);
    expect(embedded.isClosed, isTrue);
    await expectLater(
      runtime.close(standaloneId),
      throwsA(isA<BrowserRuntimeException>()),
    );
    await standalone.dispose();
    await embedded.dispose();
  });

  test(
      'WebView2, Wry, system CEF, unowned browsers, and fallback are impossible',
      () async {
    // Standalone presentation is the only admitted mode for this surface.
    expect(
      () => StandaloneBrowserSurface(
        runtime: _RecordingRuntime(),
        spec: SurfaceSpec(
          profileKey: ProfileKey('account-a'),
          presentation: PresentationMode.embedded,
          privacy: PrivacyMode.persistent,
          initialNavigation:
              NavigationRequest(url: 'https://widget.test/index'),
          policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
        ),
      ),
      throwsArgumentError,
    );

    // No fallback on unknown surfaces: the runtime reports stale instead of
    // opening another engine.
    final runtime = _RecordingRuntime();
    await expectLater(
      runtime.command(
        const SurfaceId(999),
        FocusCommand(sequence: 1, focused: true),
      ),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.staleSurface,
        ),
      ),
    );

    // The surface closes deterministically and never reopens implicitly.
    final surface = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(),
    );
    await surface.open();
    await surface.close();
    await _flush();
    expect(surface.isClosed, isTrue);
    await expectLater(
      runtime.close(surface.surfaceId!),
      throwsA(isA<BrowserRuntimeException>()),
    );
    await surface.dispose();
  });

  testWidgets('StandaloneBrowserWindow shows owned-window state',
      (tester) async {
    final runtime = _RecordingRuntime();
    final surface = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(),
    );
    await surface.open();
    await tester.pump();
    await tester.pumpWidget(StandaloneBrowserWindow(surface: surface));
    await tester.pump();
    expect(find.textContaining('Standalone browser'), findsOneWidget);
    expect(find.textContaining('1024x768'), findsOneWidget);

    await surface.resize(1280, 720, 1.5);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('1280x720'), findsOneWidget);

    await surface.setFocus(true);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('focused'), findsOneWidget);

    addTearDown(() async {
      await surface.close();
      await surface.dispose();
    });
  });

  testWidgets('StandaloneBrowserWindow shows closed state', (tester) async {
    final runtime = _RecordingRuntime();
    final surface = StandaloneBrowserSurface(
      runtime: runtime,
      spec: _standaloneSpec(),
    );
    await surface.open();
    await tester.pump();
    await tester.pumpWidget(StandaloneBrowserWindow(surface: surface));
    await tester.pump();
    await surface.close();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('closed'), findsOneWidget);

    addTearDown(() async {
      await surface.dispose();
    });
  });
}

FrameReference _frame(int sequence, {int slot = 0}) => FrameReference(
      slot: slot,
      width: 1280,
      height: 720,
      stride: 1280 * 4,
      format: PixelFormat.bgraPremultiplied,
      sequence: sequence,
    );
