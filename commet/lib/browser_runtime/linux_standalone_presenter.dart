import 'browser_runtime.dart';

/// Native Linux standalone Matrix presentation contract.
///
/// Matrix widgets open in roscord-owned X11 and Wayland windows using the
/// common OSR/CPU presenter. Both compositor cells share one
/// release-authoritative path: CEF windowless/off-screen rendering with CPU
/// `OnPaint` copied into client-owned memory and presented inside a
/// roscord-owned top-level window. There is no native child embedding on
/// either compositor, no unowned browser window, and forced CPU/software
/// rendering satisfies the full functional contract.
///
/// This library owns the pure presentation policy; the out-of-process
/// `cef_host` enforces it at its OSR callbacks while the Rust
/// `browser_linux_standalone` module mirrors these rules for host-side
/// fixtures. Matrix protocol behavior stays in `MatrixWidgetAdapter`; this
/// presenter only moves typed `BrowserRuntime` commands, frame references,
/// and owned-window state.
enum LinuxStandaloneCompositor { x11, wayland }

/// Release-authoritative rendering for Linux standalone surfaces. CPU/OSR is
/// the only production value; accelerated imports (dma-buf or otherwise)
/// remain gated experiments and are never required.
enum LinuxStandaloneRendering { cpuOsr }

/// Owned-window stacking relative to sibling roscord windows. The window
/// manager owns the final stacking; this value only records the app's
/// requested z-order so tests can assert bring-to-front/send-to-back without
/// reaching into X11/Wayland APIs.
enum LinuxStandaloneZOrder { background, normal, foreground }

/// Shared-memory frame ring budget mirrored from the wire limit. Frames are
/// references to client-owned storage, never borrowed CEF buffers.
const int linuxStandaloneMaxFrameBytes = defaultBrowserRuntimeMaxFrameBytes;

/// The only supported backend name for Linux standalone surfaces.
const String linuxStandaloneBackend = 'cef-osr-cpu';

/// Shared owned-window presentation path reported by both compositor cells.
/// Distinct from the embedded Flutter-texture path so fixtures can tell the
/// two presentations apart while proving they share the same OSR/CPU engine.
const String linuxStandalonePresentationPathValue = 'osr-cpu-owned-window';

/// Parses the compositor from the session type. Matching is exact and
/// lowercase so an unknown compositor cannot silently select a fallback
/// presentation path.
LinuxStandaloneCompositor parseLinuxStandaloneCompositor(String? sessionType) {
  return switch (sessionType) {
    'x11' => LinuxStandaloneCompositor.x11,
    'wayland' => LinuxStandaloneCompositor.wayland,
    _ => throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'unknown Linux compositor; X11 and Wayland are the only cells',
      ),
  };
}

/// Presentation path shared by both compositor cells.
String linuxStandalonePresentationPath(LinuxStandaloneCompositor compositor) {
  return switch (compositor) {
    LinuxStandaloneCompositor.x11 => linuxStandalonePresentationPathValue,
    LinuxStandaloneCompositor.wayland => linuxStandalonePresentationPathValue,
  };
}

bool get linuxStandaloneUsesOsrCpuFrames => true;
bool get linuxStandaloneUsesOwnedWindow => true;
bool get linuxStandaloneUsesNativeChildEmbedding => false;
bool get linuxStandaloneUsesUnownedBrowserWindow => false;
bool get linuxStandaloneForcedCpuRendering => true;

/// Backend names that must never back a Linux standalone surface. Matching
/// is case-insensitive and substring-based so a renamed fallback cannot slip
/// through the presentation seam. Native child embedding and unowned windows
/// are denied alongside the engine names.
bool isForbiddenStandaloneBackend(String name) {
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
      lowered.contains('unowned-browser') ||
      lowered.contains('unowned window') ||
      lowered.contains('unowned-window') ||
      lowered.contains('unowned') ||
      lowered.contains('native child') ||
      lowered.contains('native-child') ||
      lowered.contains('child embedding') ||
      lowered.contains('child-embedding') ||
      lowered.contains('child');
}

/// Rejects fallback engines, native child embedding, and unowned windows
/// without guessing an alternative. The caller must route through the bundled
/// CEF OSR/CPU host inside a roscord-owned window instead.
void assertNoStandaloneFallback(String name) {
  if (isForbiddenStandaloneBackend(name)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'fallback engines, child embedding, and unowned windows are not used '
      'for Linux standalone surfaces',
    );
  }
}

/// Resolves the requested backend to the single supported value. Anything
/// else is a fail-closed error, never a silent substitution.
String resolveLinuxStandaloneBackend(String requested) {
  assertNoStandaloneFallback(requested);
  if (requested == linuxStandaloneBackend || requested == 'cef') {
    return linuxStandaloneBackend;
  }
  throw const BrowserRuntimeException(
    BrowserRuntimeErrorCode.invalidSpec,
    'unknown Linux standalone backend; cef-osr-cpu is the only backend',
  );
}

/// Validates one OSR/CPU frame reference for the owned-window path.
/// Mirrors [FrameReference] plus the shared-memory budget; CEF pointers and
/// borrowed buffers never reach this seam.
FrameReference validateLinuxStandaloneFrame({
  required int slot,
  required int width,
  required int height,
  required int stride,
  required PixelFormat format,
  required int sequence,
  int maxFrameBytes = linuxStandaloneMaxFrameBytes,
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

/// Owned-window geometry for one Linux standalone surface.
///
/// The host owns the CEF browser; roscord owns the top-level X11/Wayland
/// window that presents the client-owned OSR frames. Origin, size, scale,
/// visibility, and requested z-order are app-owned values validated here so
/// both compositors share one geometry contract.
class LinuxStandaloneGeometry {
  final double x;
  final double y;
  final int width;
  final int height;
  final double deviceScaleFactor;
  final bool visible;
  final LinuxStandaloneZOrder zOrder;

  LinuxStandaloneGeometry({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.deviceScaleFactor,
    this.visible = true,
    this.zOrder = LinuxStandaloneZOrder.normal,
  }) {
    if (!x.isFinite || !y.isFinite) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'standalone window origin must be finite',
      );
    }
    if (width <= 0 || height <= 0) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'standalone window size must be positive',
      );
    }
    if (!deviceScaleFactor.isFinite || deviceScaleFactor <= 0) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'standalone window scale must be positive',
      );
    }
  }

  LinuxStandaloneGeometry copyWith({
    double? x,
    double? y,
    int? width,
    int? height,
    double? deviceScaleFactor,
    bool? visible,
    LinuxStandaloneZOrder? zOrder,
  }) {
    return LinuxStandaloneGeometry(
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      deviceScaleFactor: deviceScaleFactor ?? this.deviceScaleFactor,
      visible: visible ?? this.visible,
      zOrder: zOrder ?? this.zOrder,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is LinuxStandaloneGeometry &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.deviceScaleFactor == deviceScaleFactor &&
      other.visible == visible &&
      other.zOrder == zOrder;

  @override
  int get hashCode =>
      Object.hash(x, y, width, height, deviceScaleFactor, visible, zOrder);
}

/// Validates an owned-window geometry without constructing a presenter.
/// Rejects non-positive sizes, non-finite origins/scales, and unknown
/// compositors so both cells fail closed on bad window state.
LinuxStandaloneGeometry validateLinuxStandaloneGeometry({
  required double x,
  required double y,
  required int width,
  required int height,
  required double deviceScaleFactor,
  bool visible = true,
  LinuxStandaloneZOrder zOrder = LinuxStandaloneZOrder.normal,
}) {
  return LinuxStandaloneGeometry(
    x: x,
    y: y,
    width: width,
    height: height,
    deviceScaleFactor: deviceScaleFactor,
    visible: visible,
    zOrder: zOrder,
  );
}

/// Builds the standalone [SurfaceSpec] for a Matrix widget launch.
///
/// The spec shares the stable local account-record profile key, the initial
/// widget navigation, and the declared page/parent origins with the embedded
/// spec; only [PresentationMode.standalone] differs. Matrix capability names
/// stay out of the host policy.
SurfaceSpec linuxStandaloneSurfaceSpec({
  required ProfileKey profileKey,
  required NavigationRequest initialNavigation,
  required SurfacePolicy policy,
  PrivacyMode privacy = PrivacyMode.persistent,
}) {
  return SurfaceSpec(
    profileKey: profileKey,
    presentation: PresentationMode.standalone,
    privacy: privacy,
    initialNavigation: initialNavigation,
    policy: policy,
  );
}

/// Owned-window presenter for one Linux standalone surface.
///
/// The presenter is runtime-agnostic: tests attach it to a
/// [FakeBrowserRuntime] while production attaches it to the real host behind
/// the same four-operation seam. The same OSR/CPU frame ring as embedded is
/// presented inside the roscord-owned window instead of a Flutter texture.
/// Frame-ready events coalesce to the newest client-owned frame; every other
/// control event is preserved in order. Geometry, z-order, focus, input, IME,
/// resize/DPI, popup ownership, and close delegate to ordered
/// [BrowserRuntime] commands and locally validated window state so behavior
/// matches on X11 and Wayland.
///
/// Host loss never takes down the app: [noteHostLost] records a
/// runtime-lost observation, drops the pending frame, and exposes an
/// accessible reconnecting state. The surface can still be closed, and other
/// surfaces on the same runtime remain usable.
class LinuxStandalonePresenter {
  final BrowserRuntime runtime;
  final SurfaceId surfaceId;
  final ProfileKey profileKey;
  final LinuxStandaloneCompositor compositor;
  final LinuxStandaloneRendering rendering;

  int _nextCommandSequence = 1;
  FrameReadyEvent? _pendingFrame;
  bool _closed = false;
  bool _hostLost = false;
  LinuxStandaloneGeometry _geometry;
  bool _focused;

  LinuxStandalonePresenter({
    required this.runtime,
    required this.surfaceId,
    required this.profileKey,
    required this.compositor,
    this.rendering = LinuxStandaloneRendering.cpuOsr,
    LinuxStandaloneGeometry? initialGeometry,
    bool initiallyFocused = false,
  })  : _geometry = initialGeometry ??
            LinuxStandaloneGeometry(
              x: 0,
              y: 0,
              width: 800,
              height: 600,
              deviceScaleFactor: 1,
            ),
        _focused = initiallyFocused {
    if (rendering != LinuxStandaloneRendering.cpuOsr) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'Linux standalone surfaces require forced CPU/OSR rendering',
      );
    }
  }

  /// Shared owned-window presentation path for this cell. Both compositors
  /// report the same OSR/CPU owned-window value.
  String get presentationPath => linuxStandalonePresentationPath(compositor);

  bool get usesNativeChildEmbedding => linuxStandaloneUsesNativeChildEmbedding;
  bool get usesOwnedWindow => linuxStandaloneUsesOwnedWindow;
  bool get usesUnownedBrowserWindow => linuxStandaloneUsesUnownedBrowserWindow;

  /// Newest pending client-owned frame, if any. Older frames are dropped;
  /// control events are never coalesced here.
  FrameReadyEvent? get pendingFrame => _pendingFrame;

  LinuxStandaloneGeometry get geometry => _geometry;
  bool get focused => _focused;
  bool get isClosed => _closed;

  /// Accessible reconnecting state shown when the host is lost. The rest of
  /// roscord remains usable while this surface reports reconnecting.
  bool get isReconnecting => _hostLost && !_closed;
  bool get isHostLost => _hostLost;

  /// Records one host event. Frames for another surface are ignored; the
  /// newest frame for this surface wins. Window changes update the locally
  /// tracked geometry/focus so X11 and Wayland stay aligned.
  void noteEvent(SurfaceEvent event) {
    if (event.surfaceId != surfaceId) return;
    if (event is FrameReadyEvent) {
      _pendingFrame = event;
    } else if (event is WindowChangedEvent) {
      final change = event.change;
      if (change is ResizedWindow) {
        _geometry = _geometry.copyWith(
          width: change.width,
          height: change.height,
          deviceScaleFactor: change.deviceScaleFactor,
        );
      } else if (change is FocusedWindow) {
        _focused = change.focused;
      }
    }
  }

  /// Takes the newest pending frame and clears it. Returns null when no
  /// frame is pending or after host loss drops the frame.
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
    _geometry = _geometry.copyWith(
      width: width,
      height: height,
      deviceScaleFactor: deviceScaleFactor,
    );
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

  Future<void> move({required double x, required double y}) {
    if (!x.isFinite || !y.isFinite) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidCommand,
        'standalone window origin must be finite',
      );
    }
    _geometry = _geometry.copyWith(x: x, y: y);
    // Origin is window-manager owned; no host command carries it, but the
    // validated value is tracked so both compositors share one geometry
    // contract. Return an ordered no-op through the seam to preserve command
    // ordering with concurrent resize/focus traffic.
    return _command(
      FocusCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        focused: _focused,
      ),
    );
  }

  Future<void> setGeometry(LinuxStandaloneGeometry geometry) {
    _geometry = geometry;
    return _command(
      ResizeCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        width: geometry.width,
        height: geometry.height,
        deviceScaleFactor: geometry.deviceScaleFactor,
      ),
    );
  }

  Future<void> setFocus(bool focused) {
    _focused = focused;
    return _command(
      FocusCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        focused: focused,
      ),
    );
  }

  /// Requests foreground stacking for the owned window. Tracked as
  /// window-manager state; focus is re-asserted through the seam so input
  /// routing follows the z-order change on both compositors.
  Future<void> bringToFront() {
    _geometry = _geometry.copyWith(zOrder: LinuxStandaloneZOrder.foreground);
    return setFocus(true);
  }

  /// Requests background stacking for the owned window.
  Future<void> sendToBack() {
    _geometry = _geometry.copyWith(zOrder: LinuxStandaloneZOrder.background);
    return setFocus(false);
  }

  Future<void> setVisibility(bool visible) {
    _geometry = _geometry.copyWith(visible: visible);
    return setFocus(visible && _focused);
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

  /// Builds an owned child popup spec inheriting this surface's account and
  /// privacy context. Popups never escape into an unowned native window and
  /// never escalate capabilities: the child closes with the opener.
  SurfaceSpec ownedPopupSpec({
    required NavigationRequest navigation,
    required SurfacePolicy policy,
    required PrivacyMode privacy,
  }) {
    return SurfaceSpec(
      profileKey: profileKey,
      presentation: PresentationMode.standalone,
      privacy: privacy,
      initialNavigation: navigation,
      policy: policy,
    );
  }

  /// Records a host-loss observation without taking down the app. The pending
  /// frame is dropped, the surface reports reconnecting, and [close] still
  /// wins. Other surfaces on the same runtime are untouched.
  void noteHostLost() {
    if (_closed) return;
    _hostLost = true;
    _pendingFrame = null;
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
