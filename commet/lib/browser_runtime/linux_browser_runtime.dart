import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'browser_runtime.dart';
import 'runtime_lifecycle.dart';
import 'windows_browser_runtime.dart';

/// The Linux adapter for the out-of-process CEF host.
///
/// The host is started lazily on the first [open] and is shared by every
/// surface in this desktop process, exactly like the Windows adapter. The
/// only differences are the transport (an owner-only Unix-socket endpoint
/// instead of a Windows named pipe) and the launch arguments
/// (`--socket/--parent-nonce/--cef-root` as enforced by the Rust `cef_host`).
/// Protocol, lifecycle, recovery, and presentation policy are shared with
/// [WindowsBrowserRuntime] through [CefHostFlavor.linux]; this class owns no
/// engine fallback.
class LinuxBrowserRuntime implements BrowserRuntime {
  LinuxBrowserRuntime({
    String? hostBinary,
    BrowserHostConnector? connector,
    BrowserHostStarter? starter,
    int? parentProcessId,
    Random? random,
    Duration connectTimeout = const Duration(seconds: 15),
    int maxFrameBytes = defaultBrowserRuntimeMaxFrameBytes,
    this.forceSoftwareRendering = false,
    String? profileRoot,
    String? cefRoot,
    String? socketPath,
    String? socketRoot,
  }) : _runtime = WindowsBrowserRuntime(
          hostExecutable: hostBinary,
          connector: connector ?? connectLinuxSocket,
          starter: starter,
          parentProcessId: parentProcessId,
          random: random,
          connectTimeout: connectTimeout,
          maxFrameBytes: maxFrameBytes,
          hostFlavor: CefHostFlavor.linux,
          forceSoftwareRendering: forceSoftwareRendering,
          profileRoot: profileRoot,
          cefRoot: cefRoot,
          socketPath: socketPath,
          socketRoot: socketRoot,
        );

  final WindowsBrowserRuntime _runtime;

  /// Forced software rendering keeps the CPU OnPaint frame ring authoritative
  /// when GPU import is unavailable. It never selects another browser engine;
  /// the same frame/input/resize/focus contract applies.
  final bool forceSoftwareRendering;

  /// The host topology this runtime drives. Always Linux: the endpoint is an
  /// owner-only Unix socket and launch uses the `--socket/--parent-nonce/
  /// --cef-root` arguments enforced by the Rust `cef_host`.
  CefHostFlavor get hostFlavor => CefHostFlavor.linux;

  /// Shared lifecycle controller owned by the inner runtime.
  RuntimeLifecycle get lifecycle => _runtime.lifecycle;

  @override
  Stream<SurfaceEvent> events() => _runtime.events();

  /// Lifecycle diagnostics are additive to the original surface event stream.
  Stream<RuntimeEvent> runtimeEvents() => _runtime.runtimeEvents();

  /// Feed a CEF child termination observation into the shared lifecycle
  /// policy without exposing a CEF object to Dart.
  void reportSurfaceFailure(
    SurfaceId surfaceId,
    FailureClass kind, {
    String? rawStatus,
    required String message,
  }) =>
      _runtime.reportSurfaceFailure(
        surfaceId,
        kind,
        rawStatus: rawStatus,
        message: message,
      );

  @override
  Future<SurfaceId> open(SurfaceSpec spec) => _runtime.open(spec);

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) =>
      _runtime.command(surfaceId, command);

  @override
  Future<void> close(SurfaceId surfaceId) => _runtime.close(surfaceId);

  Future<void> dispose() => _runtime.dispose();

  Future<void> retryBrowser() => _runtime.retryBrowser();

  /// Default Unix-socket connector for the Linux host endpoint.
  ///
  /// The port is ignored for Unix-domain addresses; the host binds the
  /// owner-only path supplied at launch and revalidates it before serving.
  static Future<Socket> connectLinuxSocket(String socketPath) => Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
}
