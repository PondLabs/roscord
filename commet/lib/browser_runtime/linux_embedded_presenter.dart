import 'browser_runtime.dart';

/// Native Linux embedded Matrix presentation contract.
///
/// Both required compositor cells (native X11 and native Wayland) render
/// Matrix widgets through the same path: CEF windowless/off-screen rendering
/// with CPU `OnPaint` copied into client-owned memory and presented as a
/// Flutter texture. There is no native child embedding on either compositor,
/// and forced CPU/software rendering satisfies the full functional contract.
///
/// This library owns the pure presentation policy; the out-of-process
/// `cef_host` enforces it at its OSR callbacks while the Rust
/// `browser_linux_embedded` module mirrors these rules for host-side fixtures.
/// Matrix protocol behavior stays in `MatrixWidgetAdapter`; this presenter
/// only moves typed `BrowserRuntime` commands and frame references.
enum LinuxCompositor { x11, wayland }

/// Release-authoritative rendering for Linux embedded surfaces. CPU/OSR is
/// the only production value; accelerated imports (dma-buf or otherwise)
/// remain gated experiments and are never required.
enum LinuxEmbeddedRendering { cpuOsr }

/// Shared-memory frame ring budget mirrored from the wire limit. Frames are
/// references to client-owned storage, never borrowed CEF buffers.
const int linuxEmbeddedMaxFrameBytes = defaultBrowserRuntimeMaxFrameBytes;

/// The only supported backend name for Linux embedded surfaces.
const String linuxEmbeddedBackend = 'cef-osr-cpu';

/// Parses the compositor from the session type. Matching is exact and
/// lowercase so an unknown compositor cannot silently select a fallback
/// presentation path.
LinuxCompositor parseLinuxCompositor(String? sessionType) {
  return switch (sessionType) {
    'x11' => LinuxCompositor.x11,
    'wayland' => LinuxCompositor.wayland,
    _ => throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'unknown Linux compositor; X11 and Wayland are the only cells',
      ),
  };
}

/// Presentation path shared by both compositor cells.
String linuxEmbeddedPresentationPath(LinuxCompositor compositor) {
  return switch (compositor) {
    LinuxCompositor.x11 => 'osr-cpu-flutter-texture',
    LinuxCompositor.wayland => 'osr-cpu-flutter-texture',
  };
}

bool get linuxEmbeddedUsesOsrCpuFrames => true;
bool get linuxEmbeddedUsesFlutterTexture => true;
bool get linuxEmbeddedUsesNativeChildEmbedding => false;
bool get linuxEmbeddedForcedCpuRendering => true;

/// Backend names that must never back a Linux embedded surface. Matching is
/// case-insensitive and substring-based so a renamed fallback cannot slip
/// through the presentation seam.
bool isForbiddenEmbeddedBackend(String name) {
  final lowered = name.toLowerCase();
  return lowered.contains('webkit') ||
      lowered.contains('wry') ||
      lowered.contains('webview2') ||
      lowered.contains('system cef') ||
      lowered.contains('system-cef') ||
      lowered.contains('external chromium') ||
      lowered.contains('external-chromium') ||
      lowered.contains('chromium external') ||
      lowered.contains('unowned browser') ||
      lowered.contains('unowned-browser');
}

/// Rejects fallback engines without guessing an alternative. The caller must
/// route through the bundled CEF OSR/CPU host instead.
void assertNoFallbackEngine(String name) {
  if (isForbiddenEmbeddedBackend(name)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'fallback browser engines are not used for Linux embedded surfaces',
    );
  }
}

/// Resolves the requested backend to the single supported value. Anything
/// else is a fail-closed error, never a silent substitution.
String resolveLinuxEmbeddedBackend(String requested) {
  assertNoFallbackEngine(requested);
  if (requested == linuxEmbeddedBackend || requested == 'cef') {
    return linuxEmbeddedBackend;
  }
  throw const BrowserRuntimeException(
    BrowserRuntimeErrorCode.invalidSpec,
    'unknown Linux embedded backend; cef-osr-cpu is the only backend',
  );
}

/// Validates one OSR/CPU frame reference for the Flutter texture path.
/// Mirrors [FrameReference] plus the shared-memory budget; CEF pointers and
/// borrowed buffers never reach this seam.
FrameReference validateLinuxEmbeddedFrame({
  required int slot,
  required int width,
  required int height,
  required int stride,
  required PixelFormat format,
  required int sequence,
  int maxFrameBytes = linuxEmbeddedMaxFrameBytes,
}) {
  if (slot < 0) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'frame slot is negative',
    );
  }
  final frame = FrameReference(
    slot: slot,
    width: width,
    height: height,
    stride: stride,
    format: format,
    sequence: sequence,
  );
  if (maxFrameBytes <= 0 || stride * height > maxFrameBytes) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidCommand,
      'frame exceeds the client-owned frame budget',
    );
  }
  return frame;
}

/// Flutter texture presenter for one Linux embedded surface.
///
/// The presenter is runtime-agnostic: tests attach it to a
/// [FakeBrowserRuntime] while production attaches it to the real host behind
/// the same four-operation seam. Frame-ready events coalesce to the newest
/// client-owned frame; every other control event is preserved in order.
/// Input, IME, focus, resize/DPI, and close delegate to ordered
/// [BrowserRuntime] commands so behavior matches the Windows embedded
/// surface command for command.
class LinuxEmbeddedPresenter {
  final BrowserRuntime runtime;
  final SurfaceId surfaceId;
  final ProfileKey profileKey;
  final LinuxCompositor compositor;
  final LinuxEmbeddedRendering rendering;

  int _nextCommandSequence = 1;
  FrameReadyEvent? _pendingFrame;
  bool _closed = false;
  bool _hostLost = false;

  LinuxEmbeddedPresenter({
    required this.runtime,
    required this.surfaceId,
    required this.profileKey,
    required this.compositor,
    this.rendering = LinuxEmbeddedRendering.cpuOsr,
  }) {
    if (rendering != LinuxEmbeddedRendering.cpuOsr) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'Linux embedded surfaces require forced CPU/OSR rendering',
      );
    }
  }

  /// Shared presentation path for this cell. Both compositors report the
  /// same OSR/CPU Flutter texture value.
  String get presentationPath => linuxEmbeddedPresentationPath(compositor);

  bool get usesNativeChildEmbedding => linuxEmbeddedUsesNativeChildEmbedding;

  /// Accessible reconnecting state shown when the host is lost. Host loss
  /// never takes down the app: the pending frame is dropped, the surface
  /// reports reconnecting, and [close] still wins.
  bool get isReconnecting => _hostLost && !_closed;
  bool get isHostLost => _hostLost;
  bool get isClosed => _closed;

  /// Newest pending client-owned frame, if any. Older frames are dropped;
  /// control events are never coalesced here.
  FrameReadyEvent? get pendingFrame => _pendingFrame;

  /// Records one host frame event. Frames for another surface are ignored;
  /// the newest frame for this surface wins.
  void noteEvent(SurfaceEvent event) {
    if (event.surfaceId != surfaceId) return;
    if (event is FrameReadyEvent) {
      _pendingFrame = event;
    }
  }

  /// Takes the newest pending frame and clears it. Returns null when no
  /// frame is pending.
  FrameReadyEvent? takeFrame() {
    final frame = _pendingFrame;
    _pendingFrame = null;
    return frame;
  }

  Future<void> resize({
    required int width,
    required int height,
    required double deviceScaleFactor,
  }) {
    return _command(
      ResizeCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        width: width,
        height: height,
        deviceScaleFactor: deviceScaleFactor,
      ),
    );
  }

  Future<void> setFocus(bool focused) {
    return _command(
      FocusCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        focused: focused,
      ),
    );
  }

  Future<void> sendInput(InputEvent input) {
    return _command(
      InputCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        input: input,
      ),
    );
  }

  Future<void> releaseFrame(int frameSequence) {
    return _command(
      ReleaseFrameCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        frameSequence: frameSequence,
      ),
    );
  }

  /// Closes the surface and marks the presenter unusable. A second close
  /// surfaces the host's stale-surface contract instead of double-freeing.
  /// Close always wins, including after [noteHostLost].
  Future<void> close() async {
    _ensureOpen();
    _closed = true;
    _pendingFrame = null;
    await runtime.close(surfaceId);
  }

  /// Records a host-loss observation without taking down the app. The
  /// pending frame is dropped, the surface reports reconnecting, and
  /// [close] still wins. Other surfaces on the same runtime are untouched.
  void noteHostLost() {
    if (_closed) return;
    _hostLost = true;
    _pendingFrame = null;
  }

  /// Clears the reconnecting state after the host restores this surface.
  void noteRestored() {
    _hostLost = false;
  }

  Future<void> _command(SurfaceCommand command) async {
    _ensureOpen();
    await runtime.command(surfaceId, command);
  }

  void _ensureOpen() {
    if (_closed) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.staleSurface,
        'stale surface $surfaceId',
      );
    }
  }
}
