import 'browser_runtime.dart';
import 'runtime_lifecycle.dart';
import 'windows_browser_runtime_stub.dart' show CefHostFlavor;

/// Native-only constructor surface for platforms without `dart:io`.
///
/// Browser builds keep the public library importable, but cannot launch the
/// Linux CEF host. Calling any operation is therefore an explicit error,
/// rather than an accidental browser-engine fallback.
class LinuxBrowserRuntime implements BrowserRuntime {
  LinuxBrowserRuntime({
    String? hostBinary,
    Object? connector,
    Object? starter,
    int? parentProcessId,
    Object? random,
    Duration connectTimeout = const Duration(seconds: 15),
    int maxFrameBytes = defaultBrowserRuntimeMaxFrameBytes,
    this.forceSoftwareRendering = false,
    String? profileRoot,
    String? cefRoot,
    String? socketPath,
    String? socketRoot,
  });

  final bool forceSoftwareRendering;

  /// The host topology this runtime drives. Always Linux.
  CefHostFlavor get hostFlavor => CefHostFlavor.linux;

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
    throw UnsupportedError('LinuxBrowserRuntime is only available on Linux');
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
        UnsupportedError('LinuxBrowserRuntime is only available on Linux'),
      );
}
