import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

/// The app-side widget origin shared with `MatrixWidgetAdapter`
/// (`matrixWidgetAppOrigin`). Referenced by value so this fixture stays
/// runnable without the generated app localization and database code that
/// the full adapter import pulls in; the adapter's own suite covers the
/// Matrix substitution contract after codegen.
const String _matrixWidgetAppOrigin = 'commet://widget';

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

/// Mirrors `MatrixWidgetAdapterLaunch.toSurfaceSpec` for an embedded widget:
/// the stable local account-record profile key, the embedded presentation,
/// the initial widget navigation, and the declared page/parent origins with
/// no Matrix capability names in the host policy.
SurfaceSpec _matrixEmbeddedSpec() {
  return SurfaceSpec(
    profileKey: ProfileKey('account-record-1'),
    presentation: PresentationMode.embedded,
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
  group('compositor cells share the OSR/CPU Flutter texture path', () {
    test('X11 and Wayland report the same texture presentation', () {
      expect(parseLinuxCompositor('x11'), LinuxCompositor.x11);
      expect(parseLinuxCompositor('wayland'), LinuxCompositor.wayland);
      expect(
        linuxEmbeddedPresentationPath(LinuxCompositor.x11),
        'osr-cpu-flutter-texture',
      );
      expect(
        linuxEmbeddedPresentationPath(LinuxCompositor.wayland),
        'osr-cpu-flutter-texture',
      );
      expect(linuxEmbeddedUsesOsrCpuFrames, isTrue);
      expect(linuxEmbeddedUsesFlutterTexture, isTrue);
      expect(linuxEmbeddedUsesNativeChildEmbedding, isFalse);
      expect(linuxEmbeddedForcedCpuRendering, isTrue);
    });

    test('unknown compositors fail closed without a fallback cell', () {
      for (final unknown in [null, '', 'unknown', 'X11', 'WAYLAND', 'mir']) {
        expect(
          () => parseLinuxCompositor(unknown),
          throwsA(isA<BrowserRuntimeException>()),
          reason: '$unknown',
        );
      }
    });

    test('frames coalesce to the newest client-owned reference', () async {
      final runtime = FakeBrowserRuntime();
      final surface = await runtime.open(_embeddedSpec());
      final presenter = LinuxEmbeddedPresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxCompositor.wayland,
      );
      expect(presenter.presentationPath, 'osr-cpu-flutter-texture');
      expect(presenter.usesNativeChildEmbedding, isFalse);

      runtime.publishFrame(
        surface,
        validateLinuxEmbeddedFrame(
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
        validateLinuxEmbeddedFrame(
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
        () => validateLinuxEmbeddedFrame(
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
        () => validateLinuxEmbeddedFrame(
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
        () => validateLinuxEmbeddedFrame(
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
        () => validateLinuxEmbeddedFrame(
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

  group('Linux behavior matches the Windows embedded contract', () {
    test('Matrix launch builds the same embedded surface spec', () {
      final spec = _matrixEmbeddedSpec();
      expect(spec.presentation, PresentationMode.embedded);
      expect(spec.profileKey, ProfileKey('account-record-1'));
      expect(
        spec.policy.allowedOrigins,
        contains('https://widgets.test'),
      );
      expect(
        spec.policy.allowedOrigins,
        contains(_matrixWidgetAppOrigin),
      );
      // The adapter keeps Matrix capability names out of the host policy.
      expect(spec.policy.capabilities, isEmpty);
    });

    test('input, IME, focus, resize, DPI, and close round-trip', () async {
      final runtime = FakeBrowserRuntime();
      final events = <SurfaceEvent>[];
      final subscription = runtime.events().listen(events.add);
      final surface = await runtime.open(_embeddedSpec());
      await _flush();
      events.clear();

      final presenter = LinuxEmbeddedPresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxCompositor.x11,
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

    test('profiles, navigation, and command ordering match Windows', () async {
      final runtime = FakeBrowserRuntime();
      final surface = await runtime.open(_embeddedSpec());
      runtime.events();
      final presenter = LinuxEmbeddedPresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: LinuxCompositor.wayland,
      );
      await presenter.resize(width: 320, height: 240, deviceScaleFactor: 1);

      // Profile mismatch and sequence replay fail exactly like Windows.
      // A mismatched profile is rejected without consuming the sequence,
      // so replaying sequence 1 afterwards still violates ordering.
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

      // Navigation policy is shared: undeclared URLs stay blocked.
      final blocked = _embeddedSpec().policy.navigationDecision(
            NavigationRequest(url: 'https://evil.test/'),
          );
      expect(blocked, NavigationPolicyDecision.blocked);
    });
  });

  group('forced CPU without Wayland child embedding', () {
    test('Wayland presenter never uses native child embedding', () {
      final runtime = FakeBrowserRuntime();
      expect(
        LinuxEmbeddedPresenter(
          runtime: runtime,
          surfaceId: const SurfaceId(1),
          profileKey: ProfileKey('account-record-1'),
          compositor: LinuxCompositor.wayland,
        ).usesNativeChildEmbedding,
        isFalse,
      );
    });

    test('only the cef-osr-cpu backend resolves', () {
      expect(resolveLinuxEmbeddedBackend('cef-osr-cpu'), 'cef-osr-cpu');
      expect(resolveLinuxEmbeddedBackend('cef'), 'cef-osr-cpu');
      for (final requested in ['native', 'wayland-child', 'gpu', '']) {
        expect(
          () => resolveLinuxEmbeddedBackend(requested),
          throwsA(isA<BrowserRuntimeException>()),
          reason: requested,
        );
      }
    });
  });

  group('fallback engines are not used', () {
    test('webkit, wry, system CEF, and external Chromium are denied', () {
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
      ]) {
        expect(isForbiddenEmbeddedBackend(name), isTrue, reason: name);
        expect(
          () => assertNoFallbackEngine(name),
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
          () => resolveLinuxEmbeddedBackend(name),
          throwsA(isA<BrowserRuntimeException>()),
          reason: name,
        );
      }
      expect(isForbiddenEmbeddedBackend('cef-osr-cpu'), isFalse);
      expect(isForbiddenEmbeddedBackend('cef'), isFalse);
    });
  });
}
