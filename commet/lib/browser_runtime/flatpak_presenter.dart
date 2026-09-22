import 'browser_runtime.dart';

/// Flatpak Matrix presentation contract (GNOME Platform 48, x86_64).
///
/// Flatpak embedded and standalone Matrix surfaces run from the bundled CEF
/// payload under `/app` on both required compositor cells (Flatpak X11 and
/// Flatpak Wayland). Both presentations share one release-authoritative
/// engine: CEF windowless/off-screen rendering with CPU `OnPaint` copied into
/// client-owned memory. Embedded presents as a Flutter texture; standalone
/// presents the same OSR/CPU frames inside a roscord-owned top-level window.
/// There is no host CEF, no host WebKitGTK, no native child embedding, no
/// dynamic permission broadening, and no host filesystem access. File,
/// camera, microphone, and screen capture use XDG portals; portal denial
/// never broadens the sandbox. Forced CPU/software rendering satisfies the
/// full functional contract without GPU availability.
///
/// This library owns the pure presentation policy; the out-of-process
/// `cef_host` enforces it at its OSR callbacks while the Rust
/// `browser_flatpak` module mirrors these rules for host-side fixtures.
/// Matrix protocol behavior stays in `MatrixWidgetAdapter`; this presenter
/// only moves typed `BrowserRuntime` commands, frame references, and
/// owned-window state.
enum FlatpakCompositor { x11, wayland }

/// Release-authoritative rendering for Flatpak surfaces. CPU/OSR is the only
/// production value; accelerated imports (dma-buf or otherwise) remain gated
/// experiments and are never required.
enum FlatpakRendering { cpuOsr }

/// Owned-window stacking relative to sibling roscord windows. The window
/// manager owns the final stacking; this value only records the app's
/// requested z-order so tests can assert bring-to-front/send-to-back without
/// reaching into X11/Wayland APIs.
enum FlatpakStandaloneZOrder { background, normal, foreground }

/// Shared-memory frame ring budget mirrored from the wire limit. Frames are
/// references to client-owned storage, never borrowed CEF buffers.
const int flatpakMaxFrameBytes = defaultBrowserRuntimeMaxFrameBytes;

/// The only supported backend name for Flatpak surfaces.
const String flatpakBackend = 'cef-osr-cpu';

/// Bundled CEF payload root inside the Flatpak sandbox. The host resolves no
/// host CEF: every CEF library, resource, locale, and sandbox helper loads
/// from under this root.
const String flatpakCefBundleRoot = '/app';

/// Bundled CEF library resolved from the payload (never a host path).
const String flatpakCefLibraryPath = '/app/cef/libcef.so';

/// Shared presentation paths. Embedded uses the Flutter texture path;
/// standalone uses the owned-window path. Both prove the same OSR/CPU engine.
const String flatpakEmbeddedPresentationPathValue = 'osr-cpu-flutter-texture';
const String flatpakStandalonePresentationPathValue = 'osr-cpu-owned-window';

/// Parses the compositor from the session type. Matching is exact and
/// lowercase so an unknown compositor cannot silently select a fallback
/// presentation path.
FlatpakCompositor parseFlatpakCompositor(String? sessionType) {
  return switch (sessionType) {
    'x11' => FlatpakCompositor.x11,
    'wayland' => FlatpakCompositor.wayland,
    _ => throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'unknown Flatpak compositor; X11 and Wayland are the only cells',
      ),
  };
}

/// Embedded presentation path shared by both Flatpak compositor cells.
String flatpakEmbeddedPresentationPath(FlatpakCompositor compositor) {
  return switch (compositor) {
    FlatpakCompositor.x11 => flatpakEmbeddedPresentationPathValue,
    FlatpakCompositor.wayland => flatpakEmbeddedPresentationPathValue,
  };
}

/// Standalone presentation path shared by both Flatpak compositor cells.
String flatpakStandalonePresentationPath(FlatpakCompositor compositor) {
  return switch (compositor) {
    FlatpakCompositor.x11 => flatpakStandalonePresentationPathValue,
    FlatpakCompositor.wayland => flatpakStandalonePresentationPathValue,
  };
}

/// Presentation path for one Flatpak surface in either presentation.
String flatpakPresentationPath(
  FlatpakCompositor compositor,
  PresentationMode presentation,
) {
  return switch (presentation) {
    PresentationMode.embedded => flatpakEmbeddedPresentationPath(compositor),
    PresentationMode.standalone => flatpakStandalonePresentationPath(compositor),
  };
}

bool get flatpakUsesOsrCpuFrames => true;
bool get flatpakUsesBundledCef => true;
bool get flatpakUsesHostCef => false;
bool get flatpakUsesHostWebKitGtk => false;
bool get flatpakWorksWithoutGpu => true;
bool get flatpakForcedCpuRendering => true;
bool get flatpakUsesNativeChildEmbedding => false;
bool get flatpakUsesUnownedBrowserWindow => false;
bool get flatpakRequiresPortals => true;
bool get flatpakUsesUserNamespaceSandbox => true;
bool get flatpakUsesSeccompSandbox => true;

/// Portal denial never broadens the sandbox: no manifest change, no device
/// addition, no filesystem addition, and no D-Bus broadening follows a
/// denial, dismissal, timeout, disconnect, or unsupported outcome.
bool get flatpakPortalDenialBroadensSandbox => false;

/// Capabilities that must go through XDG portals on Flatpak. File selection
/// uses the FileChooser portal, camera/microphone use the Camera portal plus
/// app mediation, and screen capture uses the ScreenCast/PipeWire portal with
/// fresh consent per request. Denial fails closed without widening the
/// sandbox.
const Set<String> flatpakPortalCapabilities = {
  'camera',
  'microphone',
  'camera+microphone',
  'display_video',
  'display_audio',
  'display_video+display_audio',
  'file',
  'download',
  'upload',
};

/// Returns true when [capability] must use an XDG portal on Flatpak.
bool flatpakUsesPortalForCapability(String capability) {
  return flatpakPortalCapabilities.contains(capability);
}

/// Asserts that a portal denial keeps the sandbox intact. A denial,
/// dismissal, timeout, disconnect, or unsupported outcome must never add a
/// device, filesystem, or D-Bus permission.
void assertFlatpakPortalDenialKeepsSandbox({required bool sandboxBroadened}) {
  if (sandboxBroadened) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'portal denial must never broaden the Flatpak sandbox',
    );
  }
}

/// Resolves the bundled CEF library path. Only paths under `/app` resolve;
/// host locations, traversal, and empty values fail closed so the host can
/// never silently load a host CEF.
String resolveFlatpakCefBundlePath(String path) {
  if (path.isEmpty) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidSpec,
      'Flatpak CEF bundle path is empty; CEF loads only from /app',
    );
  }
  if (!path.startsWith('$flatpakCefBundleRoot/')) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'Flatpak CEF loads only from the bundled /app payload',
    );
  }
  if (path.contains('..') ||
      path.contains('\0') ||
      path.runes.any((rune) => rune < 0x20)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.invalidSpec,
      'Flatpak CEF bundle path is not a safe /app path',
    );
  }
  return path;
}

/// Returns true for host CEF locations that must never back a Flatpak
/// surface. Host library directories, `/run/host`, and `/host` prefixes are
/// all host escapes.
bool isHostCefPath(String path) {
  final lowered = path.toLowerCase();
  return lowered.startsWith('/usr/lib') ||
      lowered.startsWith('/usr/local/lib') ||
      lowered.startsWith('/opt/') ||
      lowered.startsWith('/run/host') ||
      lowered.startsWith('/host') ||
      lowered.contains('host cef') ||
      lowered.contains('host-cef');
}

/// Returns true for host WebKitGTK locations that must never back a Flatpak
/// surface. The Flatpak bundle carries no WebKitGTK; the host copy is never
/// resolved.
bool isHostWebKitGtkPath(String path) {
  final lowered = path.toLowerCase();
  return lowered.contains('webkit') ||
      lowered.contains('wry') ||
      lowered.startsWith('/usr/lib') && lowered.contains('gtk');
}

/// Backend names that must never back a Flatpak surface. Matching is
/// case-insensitive and substring-based so a renamed fallback, host engine,
/// GPU-only backend, native child embedding, or unowned window cannot slip
/// through the presentation seam.
bool isForbiddenFlatpakBackend(String name) {
  final lowered = name.toLowerCase();
  return lowered.contains('webkit') ||
      lowered.contains('wry') ||
      lowered.contains('webview2') ||
      lowered.contains('system cef') ||
      lowered.contains('system-cef') ||
      lowered.contains('host cef') ||
      lowered.contains('host-cef') ||
      lowered.contains('host webkit') ||
      lowered.contains('host-webkit') ||
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

/// Rejects fallback engines, host engines, native child embedding, and
/// unowned windows without guessing an alternative. The caller must route
/// through the bundled CEF OSR/CPU host under `/app` instead.
void assertNoFlatpakFallback(String name) {
  if (isForbiddenFlatpakBackend(name)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'fallback engines, host engines, child embedding, and unowned windows '
      'are not used for Flatpak surfaces',
    );
  }
}

/// Resolves the requested backend to the single supported value. Anything
/// else is a fail-closed error, never a silent substitution. GPU-only names
/// fail here so CPU rendering stays release-authoritative.
String resolveFlatpakBackend(String requested) {
  assertNoFlatpakFallback(requested);
  if (requested == flatpakBackend || requested == 'cef') {
    return flatpakBackend;
  }
  throw const BrowserRuntimeException(
    BrowserRuntimeErrorCode.invalidSpec,
    'unknown Flatpak backend; cef-osr-cpu is the only backend',
  );
}

/// Returns true for Flatpak `finish-args` values that violate least
/// privilege. `device=all`, host/home filesystem access, host OS bindings,
/// and `flatpak-spawn --host` escapes are never allowed; portals mediate
/// files, camera, microphone, and screen capture instead.
bool isForbiddenFlatpakFinishArg(String arg) {
  final lowered = arg.toLowerCase();
  return lowered.contains('--device=all') ||
      lowered.contains('filesystem=host') ||
      lowered.contains('filesystem=home') ||
      lowered.contains('/run/host') ||
      lowered == '--filesystem=host-os' ||
      lowered.contains('host-os') ||
      lowered.contains('flatpak-spawn') ||
      lowered.contains('--talk-name=org.freedesktop.flatpak.spawn') ||
      lowered.contains('dynamic permission') ||
      lowered.contains('broadening');
}

/// Validates a Flatpak `finish-args` list against least privilege. The
/// declared network/display/audio set (ipc, fallback-x11, wayland, pulseaudio,
/// network, dri) must be present while every forbidden broadening arg fails
/// closed. Host/home filesystem access is never granted; the download
/// destination stays scoped and portal-mediated.
void validateFlatpakFinishArgs(List<String> args) {
  for (final arg in args) {
    if (isForbiddenFlatpakFinishArg(arg)) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.policyViolation,
        'Flatpak finish-args broaden the sandbox beyond least privilege',
      );
    }
  }
  const required = [
    '--share=ipc',
    '--socket=fallback-x11',
    '--socket=wayland',
    '--socket=pulseaudio',
    '--share=network',
    '--device=dri',
  ];
  for (final need in required) {
    if (!args.contains(need)) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'Flatpak finish-args miss a least-privilege permission',
      );
    }
  }
}

/// Returns true for host filesystem paths that a Flatpak surface must never
/// touch. The sandbox sees only `/app`, the app data, and portal-staged
/// copies; host roots, `/run/host`, home directories, and host CEF/WebKit
/// library paths are all forbidden.
bool isFlatpakHostFilesystemPath(String path) {
  final lowered = path.toLowerCase();
  return lowered.startsWith('/host') ||
      lowered.startsWith('/run/host') ||
      lowered.startsWith('/home/') ||
      lowered == '/home' ||
      lowered.startsWith('/root') ||
      lowered.contains('/usr/lib') && lowered.contains('cef') ||
      lowered.contains('/usr/lib') && lowered.contains('webkit') ||
      lowered.contains('host filesystem');
}

/// Rejects host filesystem access without guessing an alternative. Uploads
/// use a portal chooser plus read-only staged copies; downloads use the
/// declared safe destination with atomic commit.
void assertNoFlatpakHostFilesystemAccess(String path) {
  if (isFlatpakHostFilesystemPath(path)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'Flatpak surfaces never access the host filesystem directly',
    );
  }
  if (path.contains('..') && path.startsWith('/app') == false) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'Flatpak surfaces never escape the sandbox via traversal',
    );
  }
}

/// Returns true for operations that would dynamically broaden Flatpak
/// permissions at runtime. Talking to the host spawn portal, adding a device,
/// filesystem, or D-Bus permission after denial, or widening the manifest in
/// response to a portal outcome are all forbidden.
bool isFlatpakDynamicBroadening(String operation) {
  final lowered = operation.toLowerCase();
  return lowered.contains('flatpak-spawn') ||
      lowered.contains('flatpak override') ||
      lowered.contains('dynamic permission') ||
      lowered.contains('broaden') ||
      lowered.contains('add device') ||
      lowered.contains('add filesystem') ||
      lowered.contains('add talk-name') ||
      lowered.contains('widen the manifest');
}

/// Rejects dynamic permission broadening without guessing an alternative.
void assertNoFlatpakDynamicBroadening(String operation) {
  if (isFlatpakDynamicBroadening(operation)) {
    throw const BrowserRuntimeException(
      BrowserRuntimeErrorCode.policyViolation,
      'Flatpak permissions are never broadened dynamically',
    );
  }
}

/// Validates one OSR/CPU frame reference for the Flatpak paths.
/// Mirrors [FrameReference] plus the shared-memory budget; CEF pointers and
/// borrowed buffers never reach this seam. CPU frames stay fully functional
/// with no GPU import.
FrameReference validateFlatpakFrame({
  required int slot,
  required int width,
  required int height,
  required int stride,
  required PixelFormat format,
  required int sequence,
  int maxFrameBytes = flatpakMaxFrameBytes,
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

/// Builds the Flatpak embedded [SurfaceSpec] for a Matrix widget launch.
///
/// The spec shares the stable local account-record profile key, the initial
/// widget navigation, and the declared page/parent origins with the native
/// embedded spec; only the Flatpak bundle/sandbox context differs. Matrix
/// capability names stay out of the host policy.
SurfaceSpec flatpakEmbeddedSurfaceSpec({
  required ProfileKey profileKey,
  required NavigationRequest initialNavigation,
  required SurfacePolicy policy,
  PrivacyMode privacy = PrivacyMode.persistent,
}) {
  return SurfaceSpec(
    profileKey: profileKey,
    presentation: PresentationMode.embedded,
    privacy: privacy,
    initialNavigation: initialNavigation,
    policy: policy,
  );
}

/// Builds the Flatpak standalone [SurfaceSpec] for a Matrix widget launch.
SurfaceSpec flatpakStandaloneSurfaceSpec({
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

/// Flutter texture presenter for one Flatpak embedded surface.
///
/// The presenter is runtime-agnostic: tests attach it to a
/// [FakeBrowserRuntime] while production attaches it to the real host behind
/// the same four-operation seam. Frame-ready events coalesce to the newest
/// client-owned CPU frame; every other control event is preserved in order.
/// The bundled `/app` CEF payload backs both compositor cells with no host
/// CEF, no host WebKitGTK, and no GPU requirement.
class FlatpakEmbeddedPresenter {
  final BrowserRuntime runtime;
  final SurfaceId surfaceId;
  final ProfileKey profileKey;
  final FlatpakCompositor compositor;
  final FlatpakRendering rendering;

  int _nextCommandSequence = 1;
  FrameReadyEvent? _pendingFrame;
  bool _closed = false;

  FlatpakEmbeddedPresenter({
    required this.runtime,
    required this.surfaceId,
    required this.profileKey,
    required this.compositor,
    this.rendering = FlatpakRendering.cpuOsr,
  }) {
    if (rendering != FlatpakRendering.cpuOsr) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'Flatpak embedded surfaces require forced CPU/OSR rendering',
      );
    }
  }

  /// Shared Flutter-texture presentation path for this cell.
  String get presentationPath => flatpakEmbeddedPresentationPath(compositor);

  bool get usesNativeChildEmbedding => flatpakUsesNativeChildEmbedding;
  bool get usesBundledCef => flatpakUsesBundledCef;
  bool get usesHostCef => flatpakUsesHostCef;
  bool get usesHostWebKitGtk => flatpakUsesHostWebKitGtk;
  bool get worksWithoutGpu => flatpakWorksWithoutGpu;

  /// Bundled CEF payload root backing this surface.
  String get cefBundleRoot => flatpakCefBundleRoot;

  /// File, camera, microphone, and screen capture always use portals.
  bool get requiresPortals => flatpakRequiresPortals;

  /// Newest pending client-owned CPU frame, if any.
  FrameReadyEvent? get pendingFrame => _pendingFrame;

  void noteEvent(SurfaceEvent event) {
    if (event.surfaceId != surfaceId) return;
    if (event is FrameReadyEvent) {
      _pendingFrame = event;
    }
  }

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

/// Owned-window geometry for one Flatpak standalone surface.
class FlatpakStandaloneGeometry {
  final double x;
  final double y;
  final int width;
  final int height;
  final double deviceScaleFactor;
  final bool visible;
  final FlatpakStandaloneZOrder zOrder;

  FlatpakStandaloneGeometry({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.deviceScaleFactor,
    this.visible = true,
    this.zOrder = FlatpakStandaloneZOrder.normal,
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

  FlatpakStandaloneGeometry copyWith({
    double? x,
    double? y,
    int? width,
    int? height,
    double? deviceScaleFactor,
    bool? visible,
    FlatpakStandaloneZOrder? zOrder,
  }) {
    return FlatpakStandaloneGeometry(
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
      other is FlatpakStandaloneGeometry &&
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
FlatpakStandaloneGeometry validateFlatpakStandaloneGeometry({
  required double x,
  required double y,
  required int width,
  required int height,
  required double deviceScaleFactor,
  bool visible = true,
  FlatpakStandaloneZOrder zOrder = FlatpakStandaloneZOrder.normal,
}) {
  return FlatpakStandaloneGeometry(
    x: x,
    y: y,
    width: width,
    height: height,
    deviceScaleFactor: deviceScaleFactor,
    visible: visible,
    zOrder: zOrder,
  );
}

/// Owned-window presenter for one Flatpak standalone surface.
///
/// The same OSR/CPU frame ring as embedded is presented inside the
/// roscord-owned Flatpak window instead of a Flutter texture. Host loss never
/// takes down the app: [noteHostLost] records a runtime-lost observation,
/// drops the pending frame, and exposes an accessible reconnecting state.
class FlatpakStandalonePresenter {
  final BrowserRuntime runtime;
  final SurfaceId surfaceId;
  final ProfileKey profileKey;
  final FlatpakCompositor compositor;
  final FlatpakRendering rendering;

  int _nextCommandSequence = 1;
  FrameReadyEvent? _pendingFrame;
  bool _closed = false;
  bool _hostLost = false;
  FlatpakStandaloneGeometry _geometry;
  bool _focused;

  FlatpakStandalonePresenter({
    required this.runtime,
    required this.surfaceId,
    required this.profileKey,
    required this.compositor,
    this.rendering = FlatpakRendering.cpuOsr,
    FlatpakStandaloneGeometry? initialGeometry,
    bool initiallyFocused = false,
  })  : _geometry = initialGeometry ??
            FlatpakStandaloneGeometry(
              x: 0,
              y: 0,
              width: 800,
              height: 600,
              deviceScaleFactor: 1,
            ),
        _focused = initiallyFocused {
    if (rendering != FlatpakRendering.cpuOsr) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.invalidSpec,
        'Flatpak standalone surfaces require forced CPU/OSR rendering',
      );
    }
  }

  String get presentationPath => flatpakStandalonePresentationPath(compositor);

  bool get usesNativeChildEmbedding => flatpakUsesNativeChildEmbedding;
  bool get usesOwnedWindow => true;
  bool get usesUnownedBrowserWindow => flatpakUsesUnownedBrowserWindow;
  bool get usesBundledCef => flatpakUsesBundledCef;
  bool get usesHostCef => flatpakUsesHostCef;
  bool get worksWithoutGpu => flatpakWorksWithoutGpu;
  String get cefBundleRoot => flatpakCefBundleRoot;
  bool get requiresPortals => flatpakRequiresPortals;

  FrameReadyEvent? get pendingFrame => _pendingFrame;

  FlatpakStandaloneGeometry get geometry => _geometry;
  bool get focused => _focused;
  bool get isClosed => _closed;

  bool get isReconnecting => _hostLost && !_closed;
  bool get isHostLost => _hostLost;

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
    return _command(
      FocusCommand(
        sequence: _nextCommandSequence++,
        profileKey: profileKey,
        focused: _focused,
      ),
    );
  }

  Future<void> setGeometry(FlatpakStandaloneGeometry geometry) {
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

  Future<void> bringToFront() {
    _geometry = _geometry.copyWith(zOrder: FlatpakStandaloneZOrder.foreground);
    return setFocus(true);
  }

  Future<void> sendToBack() {
    _geometry = _geometry.copyWith(zOrder: FlatpakStandaloneZOrder.background);
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
  /// privacy context. Popups never escape into an unowned native window.
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

  void noteHostLost() {
    if (_closed) return;
    _hostLost = true;
    _pendingFrame = null;
  }

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
