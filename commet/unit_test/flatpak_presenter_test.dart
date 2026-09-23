import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

/// The app-side widget origin shared with `MatrixWidgetAdapter`
/// (`matrixWidgetAppOrigin`). Referenced by value so this fixture stays
/// runnable without the generated app localization and database code that
/// the full adapter import pulls in; the adapter's own suite covers the
/// Matrix substitution contract after codegen.
const String _matrixWidgetAppOrigin = 'commet://widget';

SurfaceSpec _flatpakEmbeddedSpec() {
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

SurfaceSpec _flatpakStandaloneSpec() {
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

/// Least-privilege Flatpak finish-args after the #125 hardening
/// (`--device=all` replaced by `--device=dri`; no host/home filesystem).
List<String> _leastPrivilegeArgs() => const [
      '--share=ipc',
      '--socket=fallback-x11',
      '--socket=wayland',
      '--socket=pulseaudio',
      '--share=network',
      '--device=dri',
    ];

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('both presentations load without host CEF, host WebKitGTK, or GPU', () {
    test('X11 and Wayland cells share the bundled OSR/CPU paths', () {
      expect(parseFlatpakCompositor('x11'), FlatpakCompositor.x11);
      expect(parseFlatpakCompositor('wayland'), FlatpakCompositor.wayland);
      expect(
        flatpakEmbeddedPresentationPath(FlatpakCompositor.x11),
        'osr-cpu-flutter-texture',
      );
      expect(
        flatpakEmbeddedPresentationPath(FlatpakCompositor.wayland),
        'osr-cpu-flutter-texture',
      );
      expect(
        flatpakStandalonePresentationPath(FlatpakCompositor.x11),
        'osr-cpu-owned-window',
      );
      expect(
        flatpakStandalonePresentationPath(FlatpakCompositor.wayland),
        'osr-cpu-owned-window',
      );
      expect(
        flatpakPresentationPath(
            FlatpakCompositor.x11, PresentationMode.embedded),
        'osr-cpu-flutter-texture',
      );
      expect(
        flatpakPresentationPath(
            FlatpakCompositor.wayland, PresentationMode.standalone),
        'osr-cpu-owned-window',
      );
      expect(flatpakUsesOsrCpuFrames, isTrue);
      expect(flatpakUsesBundledCef, isTrue);
      expect(flatpakUsesHostCef, isFalse);
      expect(flatpakUsesHostWebKitGtk, isFalse);
      expect(flatpakWorksWithoutGpu, isTrue);
    });

    test('unknown compositors fail closed without a fallback cell', () {
      for (final unknown in [null, '', 'unknown', 'X11', 'WAYLAND', 'mir']) {
        expect(
          () => parseFlatpakCompositor(unknown),
          throwsA(isA<BrowserRuntimeException>()),
          reason: '$unknown',
        );
      }
    });

    test('bundled CEF resolves only under /app', () {
      expect(resolveFlatpakCefBundlePath('/app/cef/libcef.so'),
          '/app/cef/libcef.so');
      expect(flatpakCefBundleRoot, '/app');
      expect(flatpakCefLibraryPath, startsWith('/app/'));
      for (final bad in [
        '',
        '/usr/lib/libcef.so',
        '/opt/cef/libcef.so',
        '/run/host/usr/lib/libcef.so',
        '/host/app/libcef.so',
        '/app/../host/libcef.so',
      ]) {
        expect(
          () => resolveFlatpakCefBundlePath(bad),
          throwsA(isA<BrowserRuntimeException>()),
          reason: bad,
        );
      }
      expect(isHostCefPath('/usr/lib/x86_64-linux-gnu/libcef.so'), isTrue);
      expect(isHostCefPath('/run/host/usr/lib/libcef.so'), isTrue);
      expect(isHostCefPath('/app/cef/libcef.so'), isFalse);
      expect(
          isHostWebKitGtkPath('/usr/lib/webkit2gtk-4.1/libwebkit.so'), isTrue);
      expect(isHostWebKitGtkPath('/app/cef/libcef.so'), isFalse);
    });

    test('embedded and standalone presenters load from the bundle', () async {
      final runtime = FakeBrowserRuntime();
      final embedded = await runtime.open(_flatpakEmbeddedSpec());
      final standalone = await runtime.open(_flatpakStandaloneSpec());
      final embeddedPresenter = FlatpakEmbeddedPresenter(
        runtime: runtime,
        surfaceId: embedded,
        profileKey: ProfileKey('account-record-1'),
        compositor: FlatpakCompositor.x11,
      );
      final standalonePresenter = FlatpakStandalonePresenter(
        runtime: runtime,
        surfaceId: standalone,
        profileKey: ProfileKey('account-record-1'),
        compositor: FlatpakCompositor.wayland,
      );
      expect(embeddedPresenter.cefBundleRoot, '/app');
      expect(standalonePresenter.cefBundleRoot, '/app');
      expect(embeddedPresenter.usesBundledCef, isTrue);
      expect(standalonePresenter.usesBundledCef, isTrue);
      expect(embeddedPresenter.usesHostCef, isFalse);
      expect(standalonePresenter.usesHostCef, isFalse);
      expect(embeddedPresenter.usesHostWebKitGtk, isFalse);
      expect(embeddedPresenter.worksWithoutGpu, isTrue);
      expect(standalonePresenter.worksWithoutGpu, isTrue);
      expect(embeddedPresenter.presentationPath, 'osr-cpu-flutter-texture');
      expect(standalonePresenter.presentationPath, 'osr-cpu-owned-window');
      await embeddedPresenter.close();
      await standalonePresenter.close();
    });

    test('frames coalesce to the newest client-owned CPU reference', () async {
      final runtime = FakeBrowserRuntime();
      final surface = await runtime.open(_flatpakEmbeddedSpec());
      final presenter = FlatpakEmbeddedPresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: FlatpakCompositor.wayland,
      );
      runtime.publishFrame(
        surface,
        validateFlatpakFrame(
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
        validateFlatpakFrame(
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
      final frame = presenter.takeFrame();
      expect(frame, isNotNull);
      expect(frame!.frame.sequence, 2);
      expect(presenter.takeFrame(), isNull);
      await subscription.cancel();
    });
  });

  group('user-namespace/seccomp sandboxing and least-privilege permissions',
      () {
    test('sandbox flags stay enforced', () {
      expect(flatpakUsesUserNamespaceSandbox, isTrue);
      expect(flatpakUsesSeccompSandbox, isTrue);
    });

    test('least-privilege finish-args validate without broadening', () {
      expect(() => validateFlatpakFinishArgs(_leastPrivilegeArgs()),
          returnsNormally);
      expect(
        () => validateFlatpakFinishArgs([
          '--share=ipc',
          '--socket=fallback-x11',
          '--socket=wayland',
          '--socket=pulseaudio',
          '--share=network',
          '--device=all',
        ]),
        throwsA(isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.policyViolation,
        )),
      );
      for (final bad in [
        '--device=all',
        '--filesystem=host',
        '--filesystem=home',
        '--filesystem=xdg-download --device=all',
        'flatpak-spawn --host sh',
      ]) {
        expect(isForbiddenFlatpakFinishArg(bad), isTrue, reason: bad);
      }
      expect(isForbiddenFlatpakFinishArg('--device=dri'), isFalse);
      expect(isForbiddenFlatpakFinishArg('--share=network'), isFalse);
    });

    test('missing least-privilege permissions fail closed', () {
      expect(
        () => validateFlatpakFinishArgs([
          '--share=ipc',
          '--socket=fallback-x11',
          '--socket=wayland',
          '--socket=pulseaudio',
          '--share=network',
        ]),
        throwsA(isA<BrowserRuntimeException>()),
      );
    });
  });

  group('file, camera, microphone, and screen capture use portals', () {
    test('portal capabilities cover file and all capture kinds', () {
      expect(flatpakRequiresPortals, isTrue);
      for (final capability in [
        'camera',
        'microphone',
        'camera+microphone',
        'display_video',
        'display_audio',
        'display_video+display_audio',
        'file',
        'download',
        'upload',
      ]) {
        expect(flatpakUsesPortalForCapability(capability), isTrue,
            reason: capability);
      }
      expect(flatpakUsesPortalForCapability('geolocation'), isFalse);
      final runtime = FakeBrowserRuntime();
      final presenter = FlatpakEmbeddedPresenter(
        runtime: runtime,
        surfaceId: const SurfaceId(1),
        profileKey: ProfileKey('account-record-1'),
        compositor: FlatpakCompositor.x11,
      );
      expect(presenter.requiresPortals, isTrue);
    });

    test('denial never broadens the sandbox', () {
      expect(flatpakPortalDenialBroadensSandbox, isFalse);
      expect(
          () => assertFlatpakPortalDenialKeepsSandbox(sandboxBroadened: false),
          returnsNormally);
      expect(
        () => assertFlatpakPortalDenialKeepsSandbox(sandboxBroadened: true),
        throwsA(isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.policyViolation,
        )),
      );
    });
  });

  group('CPU rendering remains fully functional', () {
    test('both presenters require forced CPU/OSR rendering', () {
      final runtime = FakeBrowserRuntime();
      expect(
        () => FlatpakEmbeddedPresenter(
          runtime: runtime,
          surfaceId: const SurfaceId(1),
          profileKey: ProfileKey('account-record-1'),
          compositor: FlatpakCompositor.x11,
          rendering: FlatpakRendering.cpuOsr,
        ),
        returnsNormally,
      );
      expect(
        () => FlatpakStandalonePresenter(
          runtime: runtime,
          surfaceId: const SurfaceId(1),
          profileKey: ProfileKey('account-record-1'),
          compositor: FlatpakCompositor.wayland,
          rendering: FlatpakRendering.cpuOsr,
        ),
        returnsNormally,
      );
      expect(flatpakForcedCpuRendering, isTrue);
      expect(flatpakWorksWithoutGpu, isTrue);
      expect(resolveFlatpakBackend('cef-osr-cpu'), 'cef-osr-cpu');
      expect(resolveFlatpakBackend('cef'), 'cef-osr-cpu');
      for (final requested in ['native', 'wayland-child', 'gpu', '']) {
        expect(
          () => resolveFlatpakBackend(requested),
          throwsA(isA<BrowserRuntimeException>()),
          reason: requested,
        );
      }
    });

    test('standalone geometry, input, resize, DPI, and close round-trip',
        () async {
      final runtime = FakeBrowserRuntime();
      final events = <SurfaceEvent>[];
      final subscription = runtime.events().listen(events.add);
      final surface = await runtime.open(_flatpakStandaloneSpec());
      await _flush();
      events.clear();

      final presenter = FlatpakStandalonePresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: FlatpakCompositor.x11,
      );
      await presenter.setGeometry(validateFlatpakStandaloneGeometry(
        x: 10,
        y: 20,
        width: 1024,
        height: 768,
        deviceScaleFactor: 2,
      ));
      expect(presenter.geometry.width, 1024);
      await presenter.resize(width: 800, height: 600, deviceScaleFactor: 2);
      await presenter.setFocus(true);
      await presenter.sendInput(
        InputEvent.pointer(kind: PointerKind.move, x: 10, y: 20),
      );
      await presenter.sendInput(
        InputEvent.ime(phase: ImePhase.commit, text: 'あ'),
      );
      await _flush();

      final changes = events.whereType<WindowChangedEvent>().toList();
      expect(changes.length, greaterThanOrEqualTo(2));
      await presenter.bringToFront();
      expect(presenter.geometry.zOrder, FlatpakStandaloneZOrder.foreground);
      await presenter.sendToBack();
      expect(presenter.geometry.zOrder, FlatpakStandaloneZOrder.background);
      await presenter.close();
      await _flush();
      expect(events.last, isA<ClosedEvent>());
      await subscription.cancel();
    });

    test('frame validation rejects bad geometry and over-budget frames', () {
      expect(
        () => validateFlatpakFrame(
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
        () => validateFlatpakFrame(
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
      'no native child embedding, dynamic broadening, or host filesystem access',
      () {
    test('presenters never use child embedding or unowned windows', () {
      final runtime = FakeBrowserRuntime();
      for (final compositor in FlatpakCompositor.values) {
        final embedded = FlatpakEmbeddedPresenter(
          runtime: runtime,
          surfaceId: const SurfaceId(1),
          profileKey: ProfileKey('account-record-1'),
          compositor: compositor,
        );
        final standalone = FlatpakStandalonePresenter(
          runtime: runtime,
          surfaceId: const SurfaceId(1),
          profileKey: ProfileKey('account-record-1'),
          compositor: compositor,
        );
        expect(embedded.usesNativeChildEmbedding, isFalse);
        expect(standalone.usesNativeChildEmbedding, isFalse);
        expect(standalone.usesOwnedWindow, isTrue);
        expect(standalone.usesUnownedBrowserWindow, isFalse);
      }
    });

    test('forbidden backends deny host engines and embedding', () {
      for (final name in [
        'WebKitGTK',
        'webkit2gtk',
        'wry',
        'system CEF',
        'host CEF',
        'host-cef',
        'external Chromium',
        'WebView2',
        'unowned browser',
        'native child',
        'wayland child embedding',
      ]) {
        expect(isForbiddenFlatpakBackend(name), isTrue, reason: name);
        expect(
          () => assertNoFlatpakFallback(name),
          throwsA(isA<BrowserRuntimeException>().having(
            (error) => error.code,
            'code',
            BrowserRuntimeErrorCode.policyViolation,
          )),
          reason: name,
        );
        expect(
          () => resolveFlatpakBackend(name),
          throwsA(isA<BrowserRuntimeException>()),
          reason: name,
        );
      }
      expect(isForbiddenFlatpakBackend('cef-osr-cpu'), isFalse);
      expect(isForbiddenFlatpakBackend('cef'), isFalse);
    });

    test('host filesystem access is rejected', () {
      for (final path in [
        '/run/host/usr/lib/libcef.so',
        '/host/home/user/Downloads/x',
        '/home/user/.config/cef',
        '/usr/lib/x86_64-linux-gnu/webkit2gtk-4.1/libwebkit.so',
      ]) {
        expect(isFlatpakHostFilesystemPath(path), isTrue, reason: path);
        expect(
          () => assertNoFlatpakHostFilesystemAccess(path),
          throwsA(isA<BrowserRuntimeException>()),
          reason: path,
        );
      }
      expect(isFlatpakHostFilesystemPath('/app/cef/libcef.so'), isFalse);
      expect(() => assertNoFlatpakHostFilesystemAccess('/app/cef/libcef.so'),
          returnsNormally);
    });

    test('dynamic permission broadening is rejected', () {
      for (final operation in [
        'flatpak-spawn --host sh',
        'flatpak override --device=all',
        'broaden permissions after denial',
        'add filesystem=xdg-download after denial',
      ]) {
        expect(isFlatpakDynamicBroadening(operation), isTrue,
            reason: operation);
        expect(
          () => assertNoFlatpakDynamicBroadening(operation),
          throwsA(isA<BrowserRuntimeException>()),
          reason: operation,
        );
      }
      expect(isFlatpakDynamicBroadening('show portal chooser'), isFalse);
    });

    test('popups stay owned children with the opener account context', () {
      final runtime = FakeBrowserRuntime();
      final presenter = FlatpakStandalonePresenter(
        runtime: runtime,
        surfaceId: const SurfaceId(1),
        profileKey: ProfileKey('account-record-1'),
        compositor: FlatpakCompositor.x11,
      );
      final popup = presenter.ownedPopupSpec(
        navigation: NavigationRequest(url: 'https://widgets.test/popup'),
        policy: SurfacePolicy(allowedOrigins: ['https://widgets.test']),
        privacy: PrivacyMode.persistent,
      );
      expect(popup.presentation, PresentationMode.standalone);
      expect(popup.profileKey, ProfileKey('account-record-1'));
    });

    test('host loss leaves the rest of roscord usable', () async {
      final runtime = FakeBrowserRuntime();
      final surface = await runtime.open(_flatpakStandaloneSpec());
      final presenter = FlatpakStandalonePresenter(
        runtime: runtime,
        surfaceId: surface,
        profileKey: ProfileKey('account-record-1'),
        compositor: FlatpakCompositor.x11,
      );
      runtime.publishFrame(
        surface,
        validateFlatpakFrame(
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

      await presenter.close();
      expect(presenter.isClosed, isTrue);
      await subscription.cancel();
    });
  });
}
