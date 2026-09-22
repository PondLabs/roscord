import 'browser_runtime.dart';
import 'runtime_lifecycle.dart';

/// Which desktop host topology a runtime drives.
///
/// The web stub mirrors the native enum so browser builds keep the public
/// library importable without launching a host.
enum CefHostFlavor { windows, linux }

/// Native-only constructor surface for platforms without `dart:io`.
///
/// Browser builds keep the public library importable, but cannot launch the
/// Windows CEF host.  Calling any operation is therefore an explicit error,
/// rather than an accidental browser-engine fallback.
class WindowsBrowserRuntime implements BrowserRuntime {
  WindowsBrowserRuntime({
    String? hostExecutable,
    Object? connector,
    Object? starter,
    int? parentProcessId,
    Object? random,
    Duration connectTimeout = const Duration(seconds: 15),
    int maxFrameBytes = defaultBrowserRuntimeMaxFrameBytes,
    this.hostFlavor = CefHostFlavor.windows,
    this.forceSoftwareRendering = false,
    String? profileRoot,
    String? cefRoot,
    String? socketPath,
    String? socketRoot,
  });

  final CefHostFlavor hostFlavor;
  final bool forceSoftwareRendering;

  final RuntimeLifecycle lifecycle = RuntimeLifecycle();

  @override
  Stream<SurfaceEvent> events() => const Stream<SurfaceEvent>.empty();

  Stream<RuntimeEvent> runtimeEvents() => const Stream<RuntimeEvent>.empty();

  void reportSurfaceFailure(
    SurfaceId surfaceId,
    FailureClass kind, {
    String? rawStatus,
    required String message,
  }) {
    throw UnsupportedError(
        'WindowsBrowserRuntime is only available on Windows');
  }

  @override
  Future<SurfaceId> open(SurfaceSpec spec) => _unsupported();

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) =>
      _unsupported();

  @override
  Future<void> close(SurfaceId surfaceId) => _unsupported();

  Future<void> dispose() => _unsupported();

  Future<void> retryBrowser() => _unsupported();

  Future<T> _unsupported<T>() => Future<T>.error(
        UnsupportedError('WindowsBrowserRuntime is only available on Windows'),
      );
}
