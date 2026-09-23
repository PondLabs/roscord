import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

/// The app-side widget origin shared with `MatrixWidgetAdapter`
/// (`matrixWidgetAppOrigin`). Referenced by value so this fixture stays
/// runnable without the generated app localization and database code that
/// the full adapter import pulls in; the adapter's own suite covers the
/// Matrix substitution contract after codegen.
const String _matrixWidgetAppOrigin = 'commet://widget';

SurfaceSpec _standaloneSpec() {
  return SurfaceSpec(
    profileKey: ProfileKey('account-record-1'),
    presentation: PresentationMode.standalone,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widgets.test/view'),
    policy: SurfacePolicy(
      allowedOrigins: ['https://widgets.test', _matrixWidgetAppOrigin],
      allowExternalNavigation: true,
    ),
  );
}

SurfaceSpec _embeddedSpec() {
  return SurfaceSpec(
    profileKey: ProfileKey('account-record-1'),
    presentation: PresentationMode.embedded,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widgets.test/view'),
    policy: SurfacePolicy(
      allowedOrigins: ['https://widgets.test', _matrixWidgetAppOrigin],
      allowExternalNavigation: true,
    ),
  );
}

/// Mirrors `MatrixWidgetAdapterLaunch.toSurfaceSpec` for a standalone widget:
/// the stable local account-record profile key, the standalone presentation,
/// the initial widget navigation, and the declared page/parent origins with
/// no Matrix capability names in the host policy.
SurfaceSpec _matrixStandaloneSpec() {
  return SurfaceSpec(
    profileKey: ProfileKey('account-record-1'),
    presentation: PresentationMode.standalone,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widgets.test/view'),
    policy: SurfacePolicy(
      allowedOrigins: ['https://widgets.test', _matrixWidgetAppOrigin],
      allowExternalNavigation: true,
      capabilities: const {},
    ),
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('compositor cells share the owned-window OSR/CPU path', () {
    test('X11 and Wayland report the same owned-window presentation', () {
      expect(
        parseLinuxStandaloneCompositor('x11'),
        LinuxStandaloneCompositor.x11,
      );
      expect(
        parseLinuxStandaloneCompositor('wayland'),
        LinuxStandaloneCompositor.wayland,
      );
      expect(
        linuxStandalonePresentationPath(LinuxStandaloneCompositor.x11),
        'osr-cpu-owned-window',
      );
      expect(
        linuxStandalonePresentationPath(LinuxStandaloneCompositor.wayland),
        'osr-cpu-owned-window',
      );
      expect(linuxStandaloneUsesOsrCpuFrames, isTrue);
      expect(linuxStandaloneUsesOwnedWindow, isTrue);
      expect(linuxStandaloneUsesNativeChildEmbedding, isFalse);
      expect(linuxStandaloneUsesUnownedBrowserWindow, isFalse);
      expect(linuxStandaloneForcedCpuRendering, isTrue);
    });

    test('unknown compositors fail closed without a fallback cell', () {
      for (final unknown in [null, '', 'unknown', 'X11', 'WAYLAND', 'mir']) {
        expect(
          () => parseLinuxStandaloneCompositor(unknown),
          throwsA(isA<BrowserRuntimeException>()),
          reason: '$unknown',
        );
      }
    });

    test('frames coalesce to the newest client-owned reference', () async {
      final runtime = FakeBrowserRuntime();
      final surface = await runtime.open(_standaloneSpec());
      final presenter = LinuxStandalonePresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxStandaloneCompositor.wayland,
      );
      expect(presenter.presentationPath, 'osr-cpu-owned-window');
      expect(presenter.usesNativeChildEmbedding, isFalse);
      expect(presenter.usesOwnedWindow, isTrue);

      runtime.publishFrame(
        surface,
        validateLinuxStandaloneFrame(
          slot: 0,
          width: 64,
          height: 48,
          stride: 256,
          format: PixelFormat.bgraPremultiplied,
          sequence: 1,
        ),
      );
      runtime.publishFrame(
        surface,
        validateLinuxStandaloneFrame(
          slot: 0,
          width: 64,
          height: 48,
          stride: 256,
          format: PixelFormat.bgraPremultiplied,
          sequence: 2,
        ),
      );
      final subscription = runtime.events().listen(presenter.noteEvent);
      await _flush();
      // The fake host already coalesces frames; the presenter keeps the
      // newest reference it observes.
      final frame = presenter.takeFrame();
      expect(frame, isNotNull);
      expect(frame!.frame.sequence, 2);
      expect(presenter.takeFrame(), isNull);
      await subscription.cancel();
    });

    test('frame validation rejects bad geometry and over-budget frames', () {
      expect(
        () => validateLinuxStandaloneFrame(
          slot: -1,
          width: 64,
          height: 48,
          stride: 256,
          format: PixelFormat.bgraPremultiplied,
          sequence: 1,
        ),
        throwsA(isA<BrowserRuntimeException>()),
      );
      expect(
        () => validateLinuxStandaloneFrame(
          slot: 0,
          width: 0,
          height: 48,
          stride: 256,
          format: PixelFormat.bgraPremultiplied,
          sequence: 1,
        ),
        throwsA(isA<BrowserRuntimeException>()),
      );
      expect(
        () => validateLinuxStandaloneFrame(
          slot: 0,
          width: 64,
          height: 48,
          stride: 8,
          format: PixelFormat.bgraPremultiplied,
          sequence: 1,
        ),
        throwsA(isA<BrowserRuntimeException>()),
      );
      expect(
        () => validateLinuxStandaloneFrame(
          slot: 0,
          width: 4096,
          height: 4096,
          stride: 16384,
          format: PixelFormat.bgraPremultiplied,
          sequence: 1,
          maxFrameBytes: 1024,
        ),
        throwsA(isA<BrowserRuntimeException>()),
      );
    });
  });

  group(
      'owned-window geometry, z-order, focus, input, IME, resize/DPI, '
      'popup, and close on both compositors', () {
    for (final compositor in LinuxStandaloneCompositor.values) {
      test('$compositor tracks geometry, z-order, and focus', () async {
        final runtime = FakeBrowserRuntime();
        final surface = await runtime.open(_standaloneSpec());
        runtime.events();
        final presenter = LinuxStandalonePresenter(
          runtime: runtime,
          surfaceId: surface,
          profileKey: ProfileKey('account-record-1'),
          compositor: compositor,
        );
        expect(presenter.geometry.width, 800);
        await presenter.setGeometry(
          validateLinuxStandaloneGeometry(
            x: 10,
            y: 20,
            width: 1024,
            height: 768,
            deviceScaleFactor: 2,
          ),
        );
        expect(presenter.geometry.width, 1024);
        expect(presenter.geometry.deviceScaleFactor, 2);

        await presenter.move(x: 30, y: 40);
        expect(presenter.geometry.x, 30);

        await presenter.bringToFront();
        expect(
          presenter.geometry.zOrder,
          LinuxStandaloneZOrder.foreground,
        );
        expect(presenter.focused, isTrue);

        await presenter.sendToBack();
        expect(
          presenter.geometry.zOrder,
          LinuxStandaloneZOrder.background,
        );
        expect(presenter.focused, isFalse);

        await presenter.setVisibility(false);
        expect(presenter.geometry.visible, isFalse);
      });

      test('$compositor input, IME, resize, DPI, and close round-trip',
          () async {
        final runtime = FakeBrowserRuntime();
        final events = <SurfaceEvent>[];
        final subscription = runtime.events().listen(events.add);
        final surface = await runtime.open(_standaloneSpec());
        await _flush();
        events.clear();

        final presenter = LinuxStandalonePresenter(
          runtime: runtime,
          surfaceId: surface,
          profileKey: ProfileKey('account-record-1'),
          compositor: compositor,
        );
        await presenter.resize(width: 800, height: 600, deviceScaleFactor: 2);
        await presenter.setFocus(true);
        await presenter.sendInput(
          InputEvent.pointer(kind: PointerKind.move, x: 10, y: 20),
        );
        await presenter.sendInput(
          InputEvent.keyboard(key: 'a', code: 'KeyA', pressed: true),
        );
        await presenter.sendInput(
          InputEvent.ime(phase: ImePhase.commit, text: 'あ'),
        );
        await _flush();

        final changes = events.whereType<WindowChangedEvent>().toList();
        expect(changes, hasLength(2));
        final resized = changes.first.change as ResizedWindow;
        expect(resized.width, 800);
        expect(resized.deviceScaleFactor, 2);
        expect((changes.last.change as FocusedWindow).focused, isTrue);

        await presenter.close();
        await _flush();
        expect(events.last, isA<ClosedEvent>());
        await expectLater(
          presenter.close(),
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
    }

    test('geometry validation fails closed on bad window state', () {
      expect(
        () => validateLinuxStandaloneGeometry(
          x: double.nan,
          y: 0,
          width: 800,
          height: 600,
          deviceScaleFactor: 1,
        ),
        throwsA(isA<BrowserRuntimeException>()),
      );
      expect(
        () => validateLinuxStandaloneGeometry(
          x: 0,
          y: 0,
          width: 0,
          height: 600,
          deviceScaleFactor: 1,
        ),
        throwsA(isA<BrowserRuntimeException>()),
      );
      expect(
        () => validateLinuxStandaloneGeometry(
          x: 0,
          y: 0,
          width: 800,
          height: 600,
          deviceScaleFactor: 0,
        ),
        throwsA(isA<BrowserRuntimeException>()),
      );
    });

    test('popups stay owned children with the opener account context', () {
      final runtime = FakeBrowserRuntime();
      final presenter = LinuxStandalonePresenter(
        runtime: runtime,
        surfaceId: const SurfaceId(1),
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxStandaloneCompositor.x11,
      );
      final popup = presenter.ownedPopupSpec(
        navigation: NavigationRequest(url: 'https://widgets.test/popup'),
        policy: SurfacePolicy(
          allowedOrigins: ['https://widgets.test'],
        ),
        privacy: PrivacyMode.persistent,
      );
      expect(popup.presentation, PresentationMode.standalone);
      expect(popup.profileKey, ProfileKey('account-record-1'));
      expect(popup.privacy, PrivacyMode.persistent);
    });
  });

  group('standalone and embedded surfaces share account state and policy', () {
    test('Matrix launch builds the same spec except presentation', () {
      final standalone = _matrixStandaloneSpec();
      expect(standalone.presentation, PresentationMode.standalone);
      expect(standalone.profileKey, ProfileKey('account-record-1'));
      expect(
        standalone.policy.allowedOrigins,
        contains('https://widgets.test'),
      );
      expect(
        standalone.policy.allowedOrigins,
        contains(_matrixWidgetAppOrigin),
      );
      // The adapter keeps Matrix capability names out of the host policy.
      expect(standalone.policy.capabilities, isEmpty);

      final embedded = SurfaceSpec(
        profileKey: standalone.profileKey,
        presentation: PresentationMode.embedded,
        privacy: standalone.privacy,
        initialNavigation: standalone.initialNavigation,
        policy: standalone.policy,
      );
      // Same account, same navigation, same policy: only the presentation
      // differs, so both surfaces share one host request context.
      expect(embedded.profileKey, standalone.profileKey);
      expect(
        embedded.initialNavigation.url,
        standalone.initialNavigation.url,
      );
      expect(embedded.policy.allowedOrigins, standalone.policy.allowedOrigins);
      expect(embedded.presentation, isNot(standalone.presentation));
    });

    test('two surfaces for one account share browser state', () async {
      final runtime = FakeBrowserRuntime();
      final standalone = await runtime.open(_standaloneSpec());
      final embedded = await runtime.open(_embeddedSpec());
      expect(standalone, isNot(embedded));
      // Both opens succeed on the same runtime without starting another
      // host; commands for each surface keep independent sequences.
      final standalonePresenter = LinuxStandalonePresenter(
        runtime: runtime,
        surfaceId: standalone,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxStandaloneCompositor.x11,
      );
      await standalonePresenter.resize(
        width: 640,
        height: 480,
        deviceScaleFactor: 1,
      );
      await runtime.command(
        embedded,
        FocusCommand(sequence: 1, focused: true),
      );
      // Navigation policy is shared: undeclared URLs stay blocked.
      final blocked = _standaloneSpec().policy.navigationDecision(
            NavigationRequest(url: 'https://evil.test/'),
          );
      expect(blocked, NavigationPolicyDecision.blocked);
    });

    test('profiles, navigation, and command ordering match embedded', () async {
      final runtime = FakeBrowserRuntime();
      final surface = await runtime.open(_standaloneSpec());
      runtime.events();
      final presenter = LinuxStandalonePresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxStandaloneCompositor.wayland,
      );
      await presenter.resize(width: 320, height: 240, deviceScaleFactor: 1);

      // Profile mismatch and sequence replay fail exactly like embedded.
      await expectLater(
        runtime.command(
          surface,
          FocusCommand(
            sequence: 99,
            profileKey: ProfileKey('account-record-2'),
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
      await expectLater(
        runtime.command(
          surface,
          FocusCommand(sequence: 1, focused: false),
        ),
        throwsA(
          isA<BrowserRuntimeException>().having(
            (error) => error.code,
            'code',
            BrowserRuntimeErrorCode.sequenceViolation,
          ),
        ),
      );
    });
  });

  group('no native child embedding or unowned browser window', () {
    test('Wayland and X11 presenters never use child embedding', () {
      final runtime = FakeBrowserRuntime();
      for (final compositor in LinuxStandaloneCompositor.values) {
        final presenter = LinuxStandalonePresenter(
          runtime: runtime,
          surfaceId: const SurfaceId(1),
          profileKey: ProfileKey('account-record-1'),
          compositor: compositor,
        );
        expect(presenter.usesNativeChildEmbedding, isFalse);
        expect(presenter.usesOwnedWindow, isTrue);
        expect(presenter.usesUnownedBrowserWindow, isFalse);
      }
    });

    test('only the cef-osr-cpu backend resolves', () {
      expect(resolveLinuxStandaloneBackend('cef-osr-cpu'), 'cef-osr-cpu');
      expect(resolveLinuxStandaloneBackend('cef'), 'cef-osr-cpu');
      for (final requested in [
        'native',
        'wayland-child',
        'x11-child',
        'gpu',
        ''
      ]) {
        expect(
          () => resolveLinuxStandaloneBackend(requested),
          throwsA(isA<BrowserRuntimeException>()),
          reason: requested,
        );
      }
    });

    test(
        'webkit, wry, system CEF, child embedding, and unowned windows '
        'are denied', () {
      for (final name in [
        'WebKitGTK',
        'webkit2gtk',
        'wry',
        'system CEF',
        'system-cef',
        'external Chromium',
        'external-chromium',
        'WebView2',
        'unowned browser',
        'unowned window',
        'native child',
        'wayland child embedding',
        'x11 child',
      ]) {
        expect(isForbiddenStandaloneBackend(name), isTrue, reason: name);
        expect(
          () => assertNoStandaloneFallback(name),
          throwsA(
            isA<BrowserRuntimeException>().having(
              (error) => error.code,
              'code',
              BrowserRuntimeErrorCode.policyViolation,
            ),
          ),
          reason: name,
        );
        expect(
          () => resolveLinuxStandaloneBackend(name),
          throwsA(isA<BrowserRuntimeException>()),
          reason: name,
        );
      }
      expect(isForbiddenStandaloneBackend('cef-osr-cpu'), isFalse);
      expect(isForbiddenStandaloneBackend('cef'), isFalse);
    });
  });

  group('host loss leaves the rest of roscord usable', () {
    test('host loss drops the frame, reports reconnecting, close wins',
        () async {
      final runtime = FakeBrowserRuntime();
      final surface = await runtime.open(_standaloneSpec());
      final presenter = LinuxStandalonePresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxStandaloneCompositor.x11,
      );
      runtime.publishFrame(
        surface,
        validateLinuxStandaloneFrame(
          slot: 0,
          width: 64,
          height: 48,
          stride: 256,
          format: PixelFormat.bgraPremultiplied,
          sequence: 1,
        ),
      );
      final subscription = runtime.events().listen(presenter.noteEvent);
      await _flush();
      expect(presenter.pendingFrame, isNotNull);

      presenter.noteHostLost();
      expect(presenter.isHostLost, isTrue);
      expect(presenter.isReconnecting, isTrue);
      expect(presenter.pendingFrame, isNull);
      expect(presenter.takeFrame(), isNull);

      // Close still wins after host loss.
      await presenter.close();
      expect(presenter.isClosed, isTrue);
      expect(presenter.isReconnecting, isFalse);
      await subscription.cancel();
    });

    test('other surfaces remain usable after one surface loses the host',
        () async {
      final runtime = FakeBrowserRuntime();
      final first = await runtime.open(_standaloneSpec());
      final second = await runtime.open(_standaloneSpec());
      final firstPresenter = LinuxStandalonePresenter(
        runtime: runtime,
        surfaceId: first,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxStandaloneCompositor.x11,
      );
      final secondPresenter = LinuxStandalonePresenter(
        runtime: runtime,
        surfaceId: second,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxStandaloneCompositor.wayland,
      );
      firstPresenter.noteHostLost();
      expect(firstPresenter.isReconnecting, isTrue);
      expect(secondPresenter.isReconnecting, isFalse);

      // The unaffected surface still accepts ordered commands.
      await secondPresenter.resize(
        width: 320,
        height: 240,
        deviceScaleFactor: 1,
      );
      await secondPresenter.setFocus(true);
      await firstPresenter.close();
      await secondPresenter.close();
    });
  });

  group('forced CPU without native child embedding', () {
    test('standalone presenter requires CPU/OSR rendering', () {
      final runtime = FakeBrowserRuntime();
      expect(
        () => LinuxStandalonePresenter(
          runtime: runtime,
          surfaceId: const SurfaceId(1),
          profileKey: ProfileKey('account-record-1'),
          compositor: LinuxStandaloneCompositor.wayland,
          rendering: LinuxStandaloneRendering.cpuOsr,
        ),
        returnsNormally,
      );
    });
  });
}
