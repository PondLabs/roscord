import 'dart:async';

import 'package:flutter/widgets.dart';

import 'browser_runtime.dart';

/// Client-owned frame ring for one embedded Windows surface.
///
/// The host copies CPU OnPaint bytes into its own memory synchronously and
/// publishes only [FrameReference] values (slot/size/stride/format/sequence).
/// This ring keeps the newest pending frame per surface, coalescing older
/// frames exactly like the wire contract requires.  Pixel bytes never cross
/// into Dart; the Flutter texture presenter references slots only, and
/// [releaseSequence] tells the caller which sequence to acknowledge with a
/// `release_frame` command after presenting.
class ClientFrameRing {
  FrameReference? _latest;
  int _releasedThrough = 0;

  FrameReference? get latest => _latest;

  bool get hasFrame => _latest != null;

  /// The next `release_frame` sequence to send after presenting [latest].
  /// Returns null when there is no unreleased frame.
  int? get releaseSequence {
    final frame = _latest;
    if (frame == null || frame.sequence <= _releasedThrough) return null;
    return frame.sequence;
  }

  /// Accepts a validated [FrameReadyEvent] frame.  Older sequences are
  /// ignored so out-of-order delivery cannot regress the texture.
  void onFrame(FrameReference frame) {
    final current = _latest;
    if (current != null && frame.sequence <= current.sequence) return;
    _latest = frame;
  }

  /// Marks [sequence] as released.  Stale releases are ignored.
  void onReleased(int sequence) {
    if (sequence > _releasedThrough) _releasedThrough = sequence;
  }

  void clear() {
    _latest = null;
  }
}

/// An embedded Windows Matrix surface rendered through CEF OSR.
///
/// Owns one [BrowserRuntime] surface in [PresentationMode.embedded], routes
/// pointer/keyboard/wheel/IME/resize/DPI/focus/close commands with strictly
/// increasing sequences, tracks the client-owned frame ring for Flutter
/// texture presentation, and never selects another browser engine.  Forced
/// software rendering uses the same code path: the host passes
/// `--cef-software-rendering` and keeps the CPU OnPaint contract identical.
class EmbeddedBrowserSurface {
  EmbeddedBrowserSurface({
    required BrowserRuntime runtime,
    required SurfaceSpec spec,
    int? textureId,
  })  : _runtime = runtime,
        _spec = spec,
        _textureId = textureId {
    if (spec.presentation != PresentationMode.embedded) {
      throw ArgumentError.value(
        spec.presentation,
        'spec.presentation',
        'EmbeddedBrowserSurface requires PresentationMode.embedded',
      );
    }
  }

  final BrowserRuntime _runtime;
  final SurfaceSpec _spec;
  final int? _textureId;

  final ClientFrameRing frames = ClientFrameRing();
  final StreamController<FrameReference> _frameStream =
      StreamController<FrameReference>.broadcast();
  final StreamController<SurfaceEvent> _surfaceEvents =
      StreamController<SurfaceEvent>.broadcast();

  StreamSubscription<SurfaceEvent>? _subscription;
  SurfaceId? _surfaceId;
  int _nextSequence = 1;
  bool _ready = false;
  bool _closed = false;
  bool _hostLost = false;

  SurfaceSpec get spec => _spec;
  SurfaceId? get surfaceId => _surfaceId;
  bool get isReady => _ready;
  bool get isClosed => _closed;

  /// Accessible reconnecting state shown when the host is lost. Host loss
  /// never takes down the app: the pending frame is dropped, the surface
  /// reports reconnecting, and [close] still wins. Other surfaces on the
  /// same runtime remain usable.
  bool get isReconnecting => _hostLost && !_closed;
  bool get isHostLost => _hostLost;
  int? get textureId => _textureId;
  FrameReference? get latestFrame => frames.latest;

  /// The newest frame is presented as a Flutter texture when a native
  /// texture id is bound; otherwise callers render [latestFrame] metadata
  /// (size/sequence) into a placeholder.  Either way frames are references
  /// to client-owned host memory, never borrowed CEF buffers.
  Stream<FrameReference> get frameStream => _frameStream.stream;
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
      case FrameReadyEvent(:final frame):
        frames.onFrame(frame);
        if (!_frameStream.isClosed) _frameStream.add(frame);
      case ClosedEvent():
        _closed = true;
        frames.clear();
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
        'embedded surface is not open',
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

  /// Ordered IME composition.  Selection offsets must satisfy
  /// `selectionStart <= selectionEnd`; the host commits text on `commit`
  /// and cancels composition on `cancel` so focus transitions stay ordered.
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

  Future<void> resize(int width, int height, double deviceScaleFactor) => _send(
        (sequence) => SurfaceCommand.resize(
          sequence: sequence,
          profileKey: _spec.profileKey,
          width: width,
          height: height,
          deviceScaleFactor: deviceScaleFactor,
        ),
      );

  Future<void> setFocus(bool focused) => _send(
        (sequence) => SurfaceCommand.focus(
          sequence: sequence,
          profileKey: _spec.profileKey,
          focused: focused,
        ),
      );

  /// Acknowledges [frameSequence] after the Flutter texture presented it.
  /// The host reuses the ring slot; no CEF handle crosses the seam.
  Future<void> releaseFrame(int frameSequence) => _send(
        (sequence) => SurfaceCommand.releaseFrame(
          sequence: sequence,
          profileKey: _spec.profileKey,
          frameSequence: frameSequence,
        ),
      ).then((_) => frames.onReleased(frameSequence));

  /// Presents the latest frame: records the release so the next
  /// `release_frame` carries the newest sequence.  Callers bind the returned
  /// reference to a Flutter [Texture] when [_textureId] is set.
  Future<void> presentLatestAsTexture() async {
    final sequence = frames.releaseSequence;
    if (sequence == null) return;
    await releaseFrame(sequence);
  }

  Future<void> close() async {
    final id = _surfaceId;
    if (id == null || _closed) return;
    _closed = true;
    frames.clear();
    await _runtime.close(id);
  }

  /// Records a host-loss observation without taking down the app. The
  /// pending frame is dropped, the surface reports reconnecting, and
  /// [close] still wins. Other surfaces on the same runtime are untouched.
  void noteHostLost() {
    if (_closed) return;
    _hostLost = true;
    frames.clear();
  }

  /// Clears the reconnecting state after the host restores this surface.
  void noteRestored() {
    _hostLost = false;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_frameStream.isClosed) await _frameStream.close();
    if (!_surfaceEvents.isClosed) await _surfaceEvents.close();
  }
}

/// Flutter composition for one embedded surface.
///
/// When [surface.textureId] is bound, the newest client-owned frame is
/// presented through a Flutter [Texture] in normal composition.  Until the
/// first frame (or when no native texture is bound in tests) a placeholder
/// shows the surface state and latest frame metadata instead of a borrowed
/// host buffer.  The widget only ever builds a Flutter texture or placeholder
/// for its owned surface and never another engine view.
class EmbeddedBrowserView extends StatefulWidget {
  const EmbeddedBrowserView({
    super.key,
    required this.surface,
    this.placeholder,
  });

  final EmbeddedBrowserSurface surface;
  final Widget? placeholder;

  @override
  State<EmbeddedBrowserView> createState() => _EmbeddedBrowserViewState();
}

class _EmbeddedBrowserViewState extends State<EmbeddedBrowserView> {
  FrameReference? _frame;
  bool _ready = false;
  bool _closed = false;
  StreamSubscription<FrameReference>? _frames;
  StreamSubscription<SurfaceEvent>? _events;

  @override
  void initState() {
    super.initState();
    _frame = widget.surface.latestFrame;
    _ready = widget.surface.isReady;
    _closed = widget.surface.isClosed;
    _frames = widget.surface.frameStream.listen((frame) {
      if (!mounted) return;
      setState(() => _frame = frame);
      // Presenting through the texture releases the previous sequence so
      // the host ring slot becomes reusable.
      widget.surface.presentLatestAsTexture();
    });
    _events = widget.surface.surfaceEvents.listen((event) {
      if (!mounted) return;
      setState(() {
        if (event is ReadyEvent) _ready = true;
        if (event is ClosedEvent) _closed = true;
      });
    });
  }

  @override
  void didUpdateWidget(EmbeddedBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.surface, widget.surface)) {
      _frames?.cancel();
      _events?.cancel();
      _frame = widget.surface.latestFrame;
      _ready = widget.surface.isReady;
      _closed = widget.surface.isClosed;
      _frames = widget.surface.frameStream.listen((frame) {
        if (!mounted) return;
        setState(() => _frame = frame);
        widget.surface.presentLatestAsTexture();
      });
      _events = widget.surface.surfaceEvents.listen((event) {
        if (!mounted) return;
        setState(() {
          if (event is ReadyEvent) _ready = true;
          if (event is ClosedEvent) _closed = true;
        });
      });
    }
  }

  @override
  void dispose() {
    _frames?.cancel();
    _events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textureId = widget.surface.textureId;
    final frame = _frame;
    if (_closed) {
      return widget.placeholder ??
          const Text('Embedded browser closed',
              textDirection: TextDirection.ltr);
    }
    if (textureId != null && frame != null) {
      return Texture(textureId: textureId);
    }
    if (frame != null) {
      // Test/placeholder composition: frame metadata proves the client-owned
      // ring is live without requiring a native texture binding.
      return Text(
        'Embedded browser ${frame.width}x${frame.height} '
        'seq=${frame.sequence} slot=${frame.slot}${_ready ? '' : ' (connecting)'}',
        textDirection: TextDirection.ltr,
      );
    }
    return widget.placeholder ??
        Text(
          _ready ? 'Embedded browser ready' : 'Connecting embedded browser…',
          textDirection: TextDirection.ltr,
        );
  }
}
