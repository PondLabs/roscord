import 'package:commet/browser_runtime.dart';
import 'package:commet/client/components/widgets/widget_component.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_component.dart';
import 'package:flutter_test/flutter_test.dart';

SurfaceSpec _embeddedSpec({String profile = 'account-a'}) {
  return SurfaceSpec(
    profileKey: ProfileKey(profile),
    presentation: PresentationMode.embedded,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
    policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
  );
}

SurfaceSpec _standaloneSpec({String profile = 'account-a'}) {
  return SurfaceSpec(
    profileKey: ProfileKey(profile),
    presentation: PresentationMode.standalone,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
    policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
  );
}

FrameReference _frame(int sequence) => FrameReference(
      slot: 0,
      width: 1280,
      height: 720,
      stride: 1280 * 4,
      format: PixelFormat.bgraPremultiplied,
      sequence: sequence,
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  group('matrixWidgetUsesCef', () {
    test('routes Windows desktop to CEF unconditionally', () {
      expect(
        matrixWidgetUsesCef(isWeb: false, isWindows: true, isLinux: false),
        isTrue,
      );
    });

    test('routes Linux desktop to CEF unconditionally', () {
      expect(
        matrixWidgetUsesCef(isWeb: false, isWindows: false, isLinux: true),
        isTrue,
      );
    });

    test('keeps web on its existing runner', () {
      expect(
        matrixWidgetUsesCef(isWeb: true, isWindows: false, isLinux: false),
        isFalse,
      );
    });

    test('keeps Android and other platforms on their runners', () {
      expect(
        matrixWidgetUsesCef(isWeb: false, isWindows: false, isLinux: false),
        isFalse,
      );
    });
  });

  group('desktop host types', () {
    test('legacy runners are gone from the host vocabulary', () {
      expect(
        WidgetHostType.values,
        unorderedEquals([
          WidgetHostType.embedded,
          WidgetHostType.standalone,
          WidgetHostType.remoteHttpClient,
          WidgetHostType.androidActivity,
        ]),
      );
    });

    test('Linux runtime selects the Unix-socket host flavor', () {
      final runtime = LinuxBrowserRuntime();
      expect(runtime.hostFlavor, CefHostFlavor.linux);
      expect(runtime.forceSoftwareRendering, isFalse);
    });

    test('Windows runtime keeps its default flavor', () {
      final runtime = WindowsBrowserRuntime();
      expect(runtime.hostFlavor, CefHostFlavor.windows);
    });
  });

  group('attached presentation surfaces', () {
    test('embedded attach is ready by construction and receives frames',
        () async {
      final runtime = FakeBrowserRuntime();
      final id = await runtime.open(_embeddedSpec());
      final surface = EmbeddedBrowserSurface.attached(
        runtime: runtime,
        spec: _embeddedSpec(),
        surfaceId: id,
      );
      expect(surface.isReady, isTrue);
      expect(surface.surfaceId, id);

      runtime.publishFrame(id, _frame(3));
      await _flush();
      expect(surface.latestFrame, isNotNull);
      expect(surface.latestFrame!.sequence, 3);

      // Presentation disposal never closes the adapter-owned surface.
      await surface.dispose();
    });

    test('embedded attach rejects a standalone spec', () async {
      final runtime = FakeBrowserRuntime();
      final id = await runtime.open(_standaloneSpec());
      expect(
        () => EmbeddedBrowserSurface.attached(
          runtime: runtime,
          spec: _standaloneSpec(),
          surfaceId: id,
        ),
        throwsArgumentError,
      );
    });

    test('standalone attach is ready by construction', () async {
      final runtime = FakeBrowserRuntime();
      final id = await runtime.open(_standaloneSpec());
      final surface = StandaloneBrowserSurface.attached(
        runtime: runtime,
        spec: _standaloneSpec(),
        surfaceId: id,
      );
      expect(surface.isReady, isTrue);
      expect(surface.surfaceId, id);
      expect(surface.geometry.width, 1024);

      await surface.dispose();
    });

    test('standalone attach rejects an embedded spec', () async {
      final runtime = FakeBrowserRuntime();
      final id = await runtime.open(_embeddedSpec());
      expect(
        () => StandaloneBrowserSurface.attached(
          runtime: runtime,
          spec: _embeddedSpec(),
          surfaceId: id,
        ),
        throwsArgumentError,
      );
    });
  });
}
