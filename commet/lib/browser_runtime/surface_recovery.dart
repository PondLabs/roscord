import 'browser_runtime.dart';
import 'runtime_lifecycle.dart';

/// Shared recovery integration for every CEF-owned surface.
///
/// Issue #127 fans in #121 (Windows embedded), #122 (Windows standalone),
/// #123 (native Linux embedded), #124 (native Linux standalone), #125
/// (Flatpak both presentations), and #126 (Windows official video through
/// MediaEmbedAdapter). Each of those ships a presenter behind the same
/// four-operation [BrowserRuntime] seam; this library is the single policy
/// that binds their host restart, renderer/GPU recovery, retry budgets,
/// terminal states, and clean-close drain to the [RuntimeLifecycle] engine.
///
/// The rules are declarative-only restoration:
/// - A host restart recreates contexts and surfaces in stable [SurfaceId]
///   order from the immutable [SurfaceSpec] plus the latest idempotent
///   presentation values (resize/DPI, bounds, visibility, focus).
/// - Side-effecting commands (navigation, script, input, popup/window
///   actions, permission decisions, downloads, clipboard, capture/uploads)
///   are never replayed. An unacknowledged command at host loss completes as
///   failed; an acknowledged command without a terminal outcome becomes
///   unknown. During restart only the latest presentation values are held.
/// - A close always wins, including after host loss.
/// - Renderer recovery is surface-scoped (at most two recoveries per surface
///   in a rolling 60s). GPU failure degrades to CPU software rendering; two
///   GPU failures in 60s pin the epoch to gpu-disabled. Retry budgets and
///   terminal states are enforced by [RuntimeLifecycle]; this layer only
///   classifies commands and orders restoration.

/// True for commands that cause a page-visible or externally visible side
/// effect and must never be replayed after a crash.
bool isSideEffectingCommand(SurfaceCommand command) {
  return switch (command) {
    NavigateCommand() ||
    InputCommand() ||
    ScriptCommand() ||
    PermissionCommand() ||
    PopupCommand() ||
    DownloadCommand() ||
    ClipboardCommand() ||
    UploadCommand() =>
      true,
    ResizeCommand() || FocusCommand() || ReleaseFrameCommand() => false,
    _ => true,
  };
}

/// True for the idempotent presentation values that may be held as "latest"
/// during a host restart and re-applied in order after restoration.
/// History, current URL beyond the declared initial navigation, unsaved page
/// state, pending permissions, and pending downloads are never held.
bool isIdempotentPresentationCommand(SurfaceCommand command) {
  return command is ResizeCommand || command is FocusCommand;
}

/// Declarative snapshot for one logical surface.
///
/// Only the immutable [SurfaceSpec] (profile/privacy context, declared
/// initial navigation and policy, presentation mode) plus the latest
/// idempotent presentation values are restored. Arbitrary history,
/// undeclared current URL, unsaved page state, pending permissions, pending
/// downloads, clipboard, and capture state are never part of the snapshot.
class SurfaceRecoverySnapshot {
  final SurfaceId surfaceId;
  final SurfaceSpec spec;
  final Map<String, String> presentation;

  SurfaceRecoverySnapshot({
    required this.surfaceId,
    required this.spec,
    Map<String, String>? presentation,
  }) : presentation = Map.unmodifiable(presentation ?? const {});

  Map<String, Object?> toJson() => {
        'surface_id': surfaceId.value,
        'profile_key_hash': '<hashed>',
        'presentation': spec.presentation.name,
        'privacy':
            spec.privacy == PrivacyMode.persistent ? 'persistent' : 'private',
        'initial_navigation': spec.initialNavigation.url,
        'held_presentation': presentation,
      };
}

/// Registry of declarative surface state shared by every presenter.
///
/// Surfaces are restored in stable [SurfaceId] order. The registry never
/// stores commands, history, page state, pending permissions, downloads,
/// clipboard, or capture handles.
class SurfaceRecoveryRegistry {
  final Map<SurfaceId, SurfaceSpec> _specs = {};
  final Map<SurfaceId, Map<String, String>> _presentation = {};

  void register(SurfaceId surfaceId, SurfaceSpec spec) {
    _specs.putIfAbsent(surfaceId, () => spec);
    _presentation.putIfAbsent(surfaceId, () => <String, String>{});
  }

  void unregister(SurfaceId surfaceId) {
    _specs.remove(surfaceId);
    _presentation.remove(surfaceId);
  }

  SurfaceSpec? specFor(SurfaceId surfaceId) => _specs[surfaceId];

  void setPresentationValue(SurfaceId surfaceId, String key, String value) {
    final values = _presentation[surfaceId];
    if (values == null) throw StateError('unknown surface $surfaceId');
    values[key] = value;
  }

  Map<String, String> presentationFor(SurfaceId surfaceId) =>
      Map.unmodifiable(_presentation[surfaceId] ?? const {});

  /// Stable restoration order: ascending [SurfaceId].
  List<SurfaceId> restoreOrder() {
    final ids = _specs.keys.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return ids;
  }

  /// Declarative snapshots in stable order for host-restart recreation.
  List<SurfaceRecoverySnapshot> declarativeSnapshots() {
    return restoreOrder()
        .map(
          (id) => SurfaceRecoverySnapshot(
            surfaceId: id,
            spec: _specs[id]!,
            presentation: _presentation[id],
          ),
        )
        .toList();
  }

  int get surfaceCount => _specs.length;
}

/// Coordinates [RuntimeLifecycle] recovery for all surfaces on one runtime.
///
/// Presenters keep their existing four-operation calls; the coordinator owns
/// the lifecycle state machine, the declarative registry, and the held
/// latest presentation commands. Side-effecting commands are never queued
/// for replay: [shouldReplayCommand] is always false, matching
/// [RuntimeLifecycle.shouldReplayCommand].
class SurfaceRecoveryCoordinator {
  final RuntimeLifecycle lifecycle = RuntimeLifecycle();
  final SurfaceRecoveryRegistry registry = SurfaceRecoveryRegistry();

  /// Latest idempotent presentation commands held while restarting.
  /// Only resize/DPI, bounds, visibility, and focus values are held;
  /// everything else is dropped at host loss.
  final Map<SurfaceId, ResizeCommand> heldResizes = {};
  final Map<SurfaceId, FocusCommand> heldFocus = {};

  void registerSurface(SurfaceId surfaceId, SurfaceSpec spec) {
    lifecycle.registerSurface(surfaceId, spec);
    registry.register(surfaceId, spec);
  }

  void unregisterSurface(SurfaceId surfaceId) {
    try {
      lifecycle.removeSurface(surfaceId);
    } on StateError {
      // Already removed from the lifecycle; registry removal still applies.
    }
    registry.unregister(surfaceId);
    heldResizes.remove(surfaceId);
    heldFocus.remove(surfaceId);
  }

  void setPresentationValue(SurfaceId surfaceId, String key, String value) {
    lifecycle.setPresentationValue(surfaceId, key, value);
    registry.setPresentationValue(surfaceId, key, value);
  }

  /// Records a presentation command. During restarting the latest value is
  /// held; otherwise callers submit it immediately. Returns true when held.
  bool holdPresentationCommand(SurfaceId surfaceId, SurfaceCommand command) {
    if (lifecycle.state != RuntimeState.restarting) return false;
    if (command is ResizeCommand) {
      heldResizes[surfaceId] = command;
      return true;
    }
    if (command is FocusCommand) {
      heldFocus[surfaceId] = command;
      return true;
    }
    return false;
  }

  /// Ordered held presentation commands for one surface after restoration.
  List<SurfaceCommand> flushHeldPresentation(SurfaceId surfaceId) {
    final held = <SurfaceCommand>[];
    final resize = heldResizes.remove(surfaceId);
    if (resize != null) held.add(resize);
    final focus = heldFocus.remove(surfaceId);
    if (focus != null) held.add(focus);
    held.sort((a, b) => a.sequence.compareTo(b.sequence));
    return held;
  }

  /// Side-effecting commands are never replayed after a crash.
  bool shouldReplayCommand(int commandId) =>
      lifecycle.shouldReplayCommand(commandId);

  /// Stable declarative restoration plan used by the host bridge.
  List<SurfaceRecoverySnapshot> restorePlan() =>
      registry.declarativeSnapshots();

  bool get gpuDisabled => lifecycle.gpuDisabled;

  RuntimeState get state => lifecycle.state;
}

/// Tracks host-loss observations for one presenter without taking down the
/// app.
///
/// Composed by every surface presenter (embedded, standalone, Linux
/// embedded/standalone, Flatpak embedded/standalone, official video). Host
/// loss drops the pending frame, exposes [isReconnecting], and still lets
/// [noteClosed] win so clean close drains without orphaning. Other surfaces
/// on the same runtime are untouched.
class SurfaceHostLossTracker {
  bool _hostLost = false;
  bool _closed = false;

  bool get isHostLost => _hostLost;
  bool get isClosed => _closed;

  /// Accessible reconnecting state: host lost but the surface can still be
  /// closed and the rest of roscord remains usable.
  bool get isReconnecting => _hostLost && !_closed;

  void noteHostLost() {
    if (_closed) return;
    _hostLost = true;
  }

  void noteRestored() {
    _hostLost = false;
  }

  void noteClosed() {
    _closed = true;
  }
}

/// Computes the stable drain order for clean shutdown.
///
/// All surfaces and their owned windows close in ascending [SurfaceId]
/// order, callbacks and profile flush drain for up to 5 seconds, then
/// CefShutdown joins the host within 10 seconds. A timeout records
/// shutdown_timeout but never schedules crash recovery during app exit;
/// clean stop never increments crash counters.
List<SurfaceId> shutdownDrainOrder(Iterable<SurfaceId> surfaceIds) {
  final ids = surfaceIds.toList()..sort((a, b) => a.value.compareTo(b.value));
  return ids;
}
