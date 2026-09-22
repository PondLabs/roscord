import 'dart:async';

import 'package:flutter/widgets.dart';

import 'browser_runtime.dart';

/// Owned-window geometry for one standalone surface.
///
/// The host owns a top-level `HWND` per standalone surface; Dart tracks the
/// last validated geometry so resize/DPI commands stay idempotent and ordered
/// with focus changes. Position is owned natively (the window manager places
/// the top-level window); size and device scale factor travel through the
/// typed `resize` command.
class StandaloneWindowGeometry {
  const StandaloneWindowGeometry({
    required this.width,
    required this.height,
    required this.deviceScaleFactor,
  });

  final int width;
  final int height;
  final double deviceScaleFactor;

  @override
  bool operator ==(Object other) =>
      other is StandaloneWindowGeometry &&
      other.width == width &&
      other.height == height &&
      other.deviceScaleFactor == deviceScaleFactor;

  @override
  int get hashCode => Object.hash(width, height, deviceScaleFactor);

  @override
  String toString() =>
      '${width}x$height @${deviceScaleFactor}x';
}

/// A standalone Windows Matrix surface in a roscord-owned window.
///
/// Owns one [BrowserRuntime] surface in [PresentationMode.standalone] through
/// the same four-operation seam as the embedded path: the same lazily started
/// host, the same account [ProfileKey] request context, and the same policy
/// and permission mediation. The surface shares one runtime with embedded
/// surfaces; no second host is started for standalone presentation.
///
/// Windowed CEF presents natively inside the owned `HWND`, so unlike the
/// embedded path this surface never emits frame events through Flutter and
/// never binds a Flutter texture. Geometry, focus, z-order, resize/DPI,
/// input, IME, popup, and close travel as ordered typed commands;
/// `window_changed` events update the locally tracked geometry and focus
/// state. Forced software rendering uses the same host flag and the same CPU
/// contract as embedded; it never selects another engine.
class StandaloneBrowserSurface {
  StandaloneBrowserSurface({
    required BrowserRuntime runtime,
    required SurfaceSpec spec,
  })  : _runtime = runtime,
        _spec = spec {
    if (spec.presentation != PresentationMode.standalone) {
      throw ArgumentError.value(
        spec.presentation,
        'spec.presentation',
        'StandaloneBrowserSurface requires PresentationMode.standalone',
      );
    }
  }

  final BrowserRuntime _runtime;
  final SurfaceSpec _spec;

  final StreamController<SurfaceEvent> _surfaceEvents =
      StreamController<SurfaceEvent>.broadcast();

  StreamSubscription<SurfaceEvent>? _subscription;
  SurfaceId? _surfaceId;
  int _nextSequence = 1;
  bool _ready = false;
  bool _closed = false;
  StandaloneWindowGeometry _geometry = const StandaloneWindowGeometry(
    width: 1024,
    height: 768,
    deviceScaleFactor: 1.0,
  );
  bool _focused = false;

  SurfaceSpec get spec => _spec;
  SurfaceId? get surfaceId => _surfaceId;
  bool get isReady => _ready;
  bool get isClosed => _closed;
  bool get isFocused => _focused;
  StandaloneWindowGeometry get geometry => _geometry;

  /// Surface lifecycle and `window_changed` geometry/focus observations.
  /// Standalone windows never produce frames; the stream carries ready,
  /// navigation, script, permission/popup/download/clipboard/upload, window,
  /// closed, and failure events only.
  Stream<SurfaceEvent> get surfaceEvents => _surfaceEvents.stream;

  Future<SurfaceId> open() async {
    if (_surfaceId != null) return _surfaceId!;
    _subscription = _runtime.events().listen(_onEvent);
    final id = await _runtime.open(_spec);
    _surfaceId = id;
    return id;
  }

  void _onEvent(SurfaceEvent event) {
    final id = _surfaceId;
    if (id != null && event.surfaceId != id) return;
    _surfaceId ??= event.surfaceId;
    if (!_surfaceEvents.isClosed) _surfaceEvents.add(event);
    switch (event) {
      case ReadyEvent():
        _ready = true;
      case WindowChangedEvent(change: ResizedWindow(:final width, :final height, :final deviceScaleFactor)):
        _geometry = StandaloneWindowGeometry(
          width: width,
          height: height,
          deviceScaleFactor: deviceScaleFactor,
        );
      case WindowChangedEvent(change: FocusedWindow(:final focused)):
        _focused = focused;
      case ClosedEvent():
        _closed = true;
      case FailedEvent():
        break;
      default:
        break;
    }
  }

  Future<void> _send(SurfaceCommand Function(int sequence) build) async {
    final id = _surfaceId;
    if (id == null || _closed) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.staleSurface,
        'standalone surface is not open',
      );
    }
    final sequence = _nextSequence++;
    await _runtime.command(id, build(sequence));
  }

  Future<void> pointer(
    PointerKind kind,
    double x,
    double y, {
    int buttons = 0,
    double deltaX = 0,
    double deltaY = 0,
  }) =>
      _send(
        (sequence) => SurfaceCommand.input(
          sequence: sequence,
          profileKey: _spec.profileKey,
          input: InputEvent.pointer(
            kind: kind,
            x: x,
            y: y,
            buttons: buttons,
            deltaX: deltaX,
            deltaY: deltaY,
          ),
        ),
      );

  Future<void> wheel(double x, double y, double deltaX, double deltaY) =>
      pointer(
        PointerKind.wheel,
        x,
        y,
        deltaX: deltaX,
        deltaY: deltaY,
      );

  Future<void> key(
    String key,
    String code, {
    int modifiers = 0,
    required bool pressed,
  }) =>
      _send(
        (sequence) => SurfaceCommand.input(
          sequence: sequence,
          profileKey: _spec.profileKey,
          input: InputEvent.keyboard(
            key: key,
            code: code,
            modifiers: modifiers,
            pressed: pressed,
          ),
        ),
      );

  /// Ordered IME composition for the owned window. Selection offsets must
  /// satisfy `selectionStart <= selectionEnd`; the host commits text on
  /// `commit` and cancels composition on `cancel` so focus transitions stay
  /// ordered. Windowed CEF also receives native IME messages through its
  /// owned `HWND`; this channel keeps scripted and assistive input ordered
  /// with the rest of the command stream.
  Future<void> ime(
    ImePhase phase,
    String text, {
    int selectionStart = 0,
    int selectionEnd = 0,
  }) =>
      _send(
        (sequence) => SurfaceCommand.input(
          sequence: sequence,
          profileKey: _spec.profileKey,
          input: InputEvent.ime(
            phase: phase,
            text: text,
            selectionStart: selectionStart,
            selectionEnd: selectionEnd,
          ),
        ),
      );

  /// Moves and rescales the owned window. The host applies the size through
  /// `SetWindowPos`/`MoveWindow` on its owned `HWND`, notifies CEF so the
  /// windowed browser repaints at the new size, and reports the validated
  /// geometry back as a `window_changed` event. DPI travels as
  /// [deviceScaleFactor].
  Future<void> resize(int width, int height, double deviceScaleFactor) =>
      _send(
        (sequence) => SurfaceCommand.resize(
          sequence: sequence,
          profileKey: _spec.profileKey,
          width: width,
          height: height,
          deviceScaleFactor: deviceScaleFactor,
        ),
      );

  /// Focuses or unfocuses the owned window. Focusing brings the `HWND` to the
  /// front (`SetForegroundWindow`/`BringWindowToTop` plus `SetWindowPos` for
  /// z-order) and delivers `SetFocus(true)` to the windowed browser;
  /// unfocusing delivers `SetFocus(false)` without destroying z-order.
  Future<void> setFocus(bool focused) => _send(
        (sequence) => SurfaceCommand.focus(
          sequence: sequence,
          profileKey: _spec.profileKey,
          focused: focused,
        ),
      );

  /// Brings the owned window to the front. This is `setFocus(true)` through
  /// the ordered command stream, so z-order changes never overtake a pending
  /// resize or input command.
  Future<void> bringToFront() => setFocus(true);

  Future<void> close() async {
    final id = _surfaceId;
    if (id == null || _closed) return;
    await _runtime.close(id);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_surfaceEvents.isClosed) await _surfaceEvents.close();
  }
}

/// Placeholder composition for one standalone surface.
///
/// Windowed CEF presents natively in its owned `HWND` outside Flutter
/// composition, so this widget only ever builds a status placeholder for its
/// owned surface: geometry, focus, and lifecycle state. It never builds a
/// texture, platform view, or another engine view.
class StandaloneBrowserWindow extends StatefulWidget {
  const StandaloneBrowserWindow({
    super.key,
    required this.surface,
    this.placeholder,
  });

  final StandaloneBrowserSurface surface;
  final Widget? placeholder;

  @override
  State<StandaloneBrowserWindow> createState() =>
      _StandaloneBrowserWindowState();
}

class _StandaloneBrowserWindowState extends State<StandaloneBrowserWindow> {
  bool _ready = false;
  bool _closed = false;
  bool _focused = false;
  StandaloneWindowGeometry? _geometry;
  StreamSubscription<SurfaceEvent>? _events;

  @override
  void initState() {
    super.initState();
    _ready = widget.surface.isReady;
    _closed = widget.surface.isClosed;
    _focused = widget.surface.isFocused;
    _geometry = widget.surface.geometry;
    _events = widget.surface.surfaceEvents.listen((event) {
      if (!mounted) return;
      setState(() {
        if (event is ReadyEvent) _ready = true;
        if (event is ClosedEvent) _closed = true;
        if (event is WindowChangedEvent) {
          switch (event.change) {
            case ResizedWindow(:final width, :final height, :final deviceScaleFactor):
              _geometry = StandaloneWindowGeometry(
                width: width,
                height: height,
                deviceScaleFactor: deviceScaleFactor,
              );
            case FocusedWindow(:final focused):
              _focused = focused;
          }
        }
      });
    });
  }

  @override
  void didUpdateWidget(StandaloneBrowserWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.surface, widget.surface)) {
      _events?.cancel();
      _ready = widget.surface.isReady;
      _closed = widget.surface.isClosed;
      _focused = widget.surface.isFocused;
      _geometry = widget.surface.geometry;
      _events = widget.surface.surfaceEvents.listen((event) {
        if (!mounted) return;
        setState(() {
          if (event is ReadyEvent) _ready = true;
          if (event is ClosedEvent) _closed = true;
          if (event is WindowChangedEvent) {
            switch (event.change) {
              case ResizedWindow(:final width, :final height, :final deviceScaleFactor):
                _geometry = StandaloneWindowGeometry(
                  width: width,
                  height: height,
                  deviceScaleFactor: deviceScaleFactor,
                );
              case FocusedWindow(:final focused):
                _focused = focused;
            }
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.placeholder != null &&
        (_closed || (!_ready && _geometry == null))) {
      return widget.placeholder!;
    }
    if (_closed) {
      return const Text('Standalone browser closed',
          textDirection: TextDirection.ltr);
    }
    final geometry = _geometry;
    final geometryText = geometry == null ? 'connecting' : '$geometry';
    final focusText = _focused ? 'focused' : 'unfocused';
    return Text(
      'Standalone browser $geometryText $focusText'
      '${_ready ? '' : ' (connecting)'}',
      textDirection: TextDirection.ltr,
    );
  }
}
