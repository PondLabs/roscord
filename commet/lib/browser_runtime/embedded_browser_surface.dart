import 'dart:async';

import 'package:browser_surface/browser_surface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'browser_input_keys.dart';
import 'browser_runtime.dart';

/// Creates the native texture an embedded surface presents into, or null
/// when this platform (or test) has none.
typedef BrowserTextureFactory = Future<BrowserSurfaceTexture?> Function();

/// Client-owned frame ring for one embedded surface.
///
/// The host copies CPU OnPaint bytes into its shared-memory frame ring
/// synchronously and publishes only [FrameReference] values
/// (ring/slot/size/stride/format/sequence).  This ring keeps the newest
/// pending frame per surface, coalescing older frames exactly like the wire
/// contract requires.  Pixel bytes never cross into Dart; the Flutter
/// texture presenter references slots only, and [releaseSequence] tells the
/// caller which sequence to acknowledge with a `release_frame` command.
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

/// An embedded surface rendered through CEF off-screen rendering.
///
/// Owns one [BrowserRuntime] surface in [PresentationMode.embedded], routes
/// pointer/keyboard/wheel/IME/resize/DPI/focus/close commands with strictly
/// increasing sequences, and presents the host's frames through a native
/// [BrowserSurfaceTexture] (the frame ring stays in shared memory; only
/// references cross into Dart).  It never selects another browser engine.
/// Forced software rendering uses the same code path: the host passes
/// `--cef-software-rendering` and keeps the CPU OnPaint contract identical.
class EmbeddedBrowserSurface {
  EmbeddedBrowserSurface({
    required BrowserRuntime runtime,
    required SurfaceSpec spec,
    int? textureId,
    BrowserTextureFactory? textureFactory,
  })  : _runtime = runtime,
        _spec = spec,
        _textureId = textureId,
        _textureFactory = textureFactory {
    if (spec.presentation != PresentationMode.embedded) {
      throw ArgumentError.value(
        spec.presentation,
        'spec.presentation',
        'EmbeddedBrowserSurface requires PresentationMode.embedded',
      );
    }
  }

  /// Attach presentation to a surface that an adapter (for example
  /// [MatrixWidgetAdapter]) already opened through the same [runtime].
  ///
  /// The adapter resolves its open only after the host's `ReadyEvent`, so an
  /// attached surface is ready by construction; subsequent frames and
  /// lifecycle events flow through the new subscription. Protocol ownership
  /// (close/dispose of the runtime surface) stays with the adapter: callers
  /// must [dispose] the presentation without [close], then dispose the
  /// adapter session.
  EmbeddedBrowserSurface.attached({
    required BrowserRuntime runtime,
    required SurfaceSpec spec,
    required SurfaceId surfaceId,
    int? textureId,
    BrowserTextureFactory? textureFactory,
  })  : _runtime = runtime,
        _spec = spec,
        _textureId = textureId,
        _textureFactory = textureFactory {
    if (spec.presentation != PresentationMode.embedded) {
      throw ArgumentError.value(
        spec.presentation,
        'spec.presentation',
        'EmbeddedBrowserSurface requires PresentationMode.embedded',
      );
    }
    _surfaceId = surfaceId;
    _ready = true;
    _subscription = _runtime.events().listen(_onEvent);
    unawaited(_createTexture());
  }

  final BrowserRuntime _runtime;
  final SurfaceSpec _spec;
  final int? _textureId;
  final BrowserTextureFactory? _textureFactory;

  final ClientFrameRing frames = ClientFrameRing();
  final StreamController<FrameReference> _frameStream =
      StreamController<FrameReference>.broadcast();
  final StreamController<SurfaceEvent> _surfaceEvents =
      StreamController<SurfaceEvent>.broadcast();

  StreamSubscription<SurfaceEvent>? _subscription;
  SurfaceId? _surfaceId;
  BrowserSurfaceTexture? _texture;
  bool _textureRequested = false;
  String? _cursor;
  int _nextSequence = 1;
  bool _ready = false;
  bool _closed = false;
  bool _disposed = false;
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

  /// The Flutter texture showing this surface: the native texture once it
  /// exists, or the id the caller supplied.
  int? get textureId => _texture?.textureId ?? _textureId;
  FrameReference? get latestFrame => frames.latest;

  /// The page's current CSS cursor keyword, if it reported one.
  String? get cursor => _cursor;

  /// Every new frame (and a repeat of the newest one once the native texture
  /// exists).  Frames are references to the host's shared-memory ring,
  /// never borrowed CEF buffers.
  Stream<FrameReference> get frameStream => _frameStream.stream;
  Stream<SurfaceEvent> get surfaceEvents => _surfaceEvents.stream;

  Future<SurfaceId> open() async {
    if (_surfaceId != null) return _surfaceId!;
    _subscription = _runtime.events().listen(_onEvent);
    unawaited(_createTexture());
    final id = await _runtime.open(_spec);
    _surfaceId = id;
    return id;
  }

  Future<void> _createTexture() async {
    if (_textureRequested || _textureId != null) return;
    _textureRequested = true;
    final factory = _textureFactory ?? BrowserSurfaceTexture.create;
    BrowserSurfaceTexture? texture;
    try {
      texture = await factory();
    } on Object {
      // No native texture (a test without the plugin, or a platform without
      // one): frames still flow and the view shows their metadata.
      texture = null;
    }
    if (texture == null) return;
    if (_disposed) {
      await texture.dispose();
      return;
    }
    _texture = texture;
    final latest = frames.latest;
    if (latest != null) {
      _presentToTexture(latest);
      if (!_frameStream.isClosed) _frameStream.add(latest);
    }
  }

  void _presentToTexture(FrameReference frame) {
    final texture = _texture;
    final buffer = frame.buffer;
    if (texture == null || buffer == null) return;
    unawaited(
      texture
          .present(
            buffer: buffer,
            slot: frame.slot,
            sequence: frame.sequence,
            width: frame.width,
            height: frame.height,
          )
          .catchError((Object _) {}),
    );
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
        final previous = frames.latest;
        frames.onFrame(frame);
        if (identical(frames.latest, frame) && !identical(previous, frame)) {
          _presentToTexture(frame);
          if (!_frameStream.isClosed) _frameStream.add(frame);
        }
      case CursorChangedEvent(:final cursor):
        _cursor = cursor;
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
    int modifiers = 0,
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
            modifiers: modifiers,
          ),
        ),
      );

  Future<void> wheel(
    double x,
    double y,
    double deltaX,
    double deltaY, {
    int modifiers = 0,
  }) =>
      pointer(
        PointerKind.wheel,
        x,
        y,
        deltaX: deltaX,
        deltaY: deltaY,
        modifiers: modifiers,
      );

  Future<void> key(
    String key,
    String code, {
    int modifiers = 0,
    required bool pressed,
    String? text,
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
            text: text,
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

  /// Answers a [PopupRequestEvent].  Surfaces never open windows of their
  /// own: [PopupAction.openExternal] asks the host to hand the URL to the
  /// app as an external navigation, when the surface policy allows it.
  Future<void> resolvePopup(String requestId, PopupAction action) => _send(
        (sequence) => SurfaceCommand.popup(
          sequence: sequence,
          profileKey: _spec.profileKey,
          requestId: requestId,
          action: action,
        ),
      );

  /// Acknowledges [frameSequence] as presented.  The shared-memory ring does
  /// not need it (each slot carries its own seqlock), so presentation does
  /// not send it per frame; it stays for callers that track releases.
  Future<void> releaseFrame(int frameSequence) => _send(
        (sequence) => SurfaceCommand.releaseFrame(
          sequence: sequence,
          profileKey: _spec.profileKey,
          frameSequence: frameSequence,
        ),
      ).then((_) => frames.onReleased(frameSequence));

  /// Presents the latest frame and records its release, so the next
  /// `release_frame` carries the newest sequence.
  Future<void> presentLatestAsTexture() async {
    final sequence = frames.releaseSequence;
    if (sequence == null) return;
    final latest = frames.latest;
    if (latest != null) _presentToTexture(latest);
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
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    final texture = _texture;
    _texture = null;
    if (texture != null) {
      try {
        await texture.dispose();
      } on Object {
        // The texture goes away with the engine anyway.
      }
    }
    if (!_frameStream.isClosed) await _frameStream.close();
    if (!_surfaceEvents.isClosed) await _surfaceEvents.close();
  }
}

/// Flutter composition and input for one embedded surface.
///
/// The newest frame is presented through a Flutter [Texture] once the native
/// texture exists.  Until the first frame (or when no native texture is
/// bound in tests) a placeholder shows the surface state and latest frame
/// metadata instead of a borrowed host buffer.  The widget
/// only ever builds a Flutter texture or placeholder for its owned surface
/// and never another engine view.
///
/// When [interactive], the view also drives the surface: it reports its size
/// and device pixel ratio, forwards pointer (including hover and leave),
/// wheel, trackpad and keyboard input, takes focus on click, and shows the
/// page's cursor.
class EmbeddedBrowserView extends StatefulWidget {
  const EmbeddedBrowserView({
    super.key,
    required this.surface,
    this.placeholder,
    this.interactive = true,
    this.focusNode,
    this.autofocus = false,
  });

  final EmbeddedBrowserSurface surface;
  final Widget? placeholder;
  final bool interactive;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<EmbeddedBrowserView> createState() => _EmbeddedBrowserViewState();
}

class _EmbeddedBrowserViewState extends State<EmbeddedBrowserView> {
  FrameReference? _frame;
  int? _shownTextureId;
  bool _ready = false;
  bool _closed = false;
  String? _cursor;
  StreamSubscription<FrameReference>? _frames;
  StreamSubscription<SurfaceEvent>? _events;

  FocusNode? _ownFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownFocusNode ??= FocusNode(debugLabel: 'browser'));

  Size? _reportedSize;
  double? _reportedScale;
  int _pressedButtons = 0;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  void _listen() {
    _frame = widget.surface.latestFrame;
    _ready = widget.surface.isReady;
    _closed = widget.surface.isClosed;
    _cursor = widget.surface.cursor;
    _frames = widget.surface.frameStream.listen((frame) {
      if (!mounted) return;
      final hadFrame = _frame != null;
      _frame = frame;
      // A bound texture updates itself; the tree only changes for the first
      // frame, a texture that just appeared, or the metadata placeholder.
      final textureId = widget.surface.textureId;
      if (!hadFrame || textureId == null || textureId != _shownTextureId) {
        setState(() {});
      }
    });
    _events = widget.surface.surfaceEvents.listen((event) {
      if (!mounted) return;
      switch (event) {
        case ReadyEvent():
          // Anything reported before the host was ready was dropped.
          _reportedSize = null;
          setState(() => _ready = true);
        case ClosedEvent():
          setState(() => _closed = true);
        case CursorChangedEvent(:final cursor):
          if (cursor != _cursor) setState(() => _cursor = cursor);
        default:
          break;
      }
    });
  }

  @override
  void didUpdateWidget(EmbeddedBrowserView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.surface, widget.surface)) {
      _frames?.cancel();
      _events?.cancel();
      _reportedSize = null;
      _pressedButtons = 0;
      _listen();
    }
  }

  @override
  void dispose() {
    _frames?.cancel();
    _events?.cancel();
    _ownFocusNode?.dispose();
    super.dispose();
  }

  void _run(Future<void> Function() send) {
    unawaited(
      send().then<void>((_) {}, onError: (Object _, StackTrace __) {
        // Input after close or host loss is a cancellation, not an error.
      }),
    );
  }

  void _reportSize(Size size, double scale) {
    if (!_ready || _closed || size.isEmpty) return;
    if (_reportedSize == size && _reportedScale == scale) return;
    _reportedSize = size;
    _reportedScale = scale;
    _run(
      () => widget.surface.resize(
        size.width.round(),
        size.height.round(),
        scale,
      ),
    );
  }

  void _pointer(
    PointerKind kind,
    Offset position, {
    int buttons = 0,
    Offset delta = Offset.zero,
  }) {
    if (!_ready || _closed) return;
    _run(
      () => widget.surface.pointer(
        kind,
        position.dx,
        position.dy,
        buttons: buttons,
        deltaX: delta.dx,
        deltaY: delta.dy,
        modifiers: currentInputModifiers(),
      ),
    );
  }

  void _onPointerDown(PointerDownEvent event) {
    if (!_focusNode.hasFocus) _focusNode.requestFocus();
    _run(() => widget.surface.setFocus(true));
    var changed = event.buttons & ~_pressedButtons;
    if (changed == 0) changed = event.buttons;
    _pressedButtons = event.buttons;
    _pointer(PointerKind.down, event.localPosition, buttons: changed);
  }

  void _onPointerUp(PointerUpEvent event) {
    var released = _pressedButtons & ~event.buttons;
    if (released == 0) released = kPrimaryButton;
    _pressedButtons = event.buttons;
    _pointer(PointerKind.up, event.localPosition, buttons: released);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      _pointer(
        PointerKind.wheel,
        event.localPosition,
        delta: event.scrollDelta,
      );
    }
  }

  // Precision touchpads report pans instead of wheel ticks; a pan that moves
  // the content down is a wheel scroll up.
  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    _pointer(
      PointerKind.wheel,
      event.localPosition,
      delta: -event.localPanDelta,
    );
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_ready || _closed) return KeyEventResult.ignored;
    final pressed = event is KeyDownEvent || event is KeyRepeatEvent;
    _run(
      () => widget.surface.key(
        w3cKey(event),
        w3cCode(event.physicalKey),
        modifiers: currentInputModifiers(),
        pressed: pressed,
        text: typedText(event),
      ),
    );
    // Escape also reaches the app, which uses it to leave fullscreen or
    // close the surface's dialog.
    return event.logicalKey == LogicalKeyboardKey.escape
        ? KeyEventResult.ignored
        : KeyEventResult.handled;
  }

  Widget _content() {
    final textureId = widget.surface.textureId;
    final frame = _frame;
    if (_closed) {
      return widget.placeholder ??
          const Text('Embedded browser closed',
              textDirection: TextDirection.ltr);
    }
    if (textureId != null && frame != null) {
      _shownTextureId = textureId;
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

  @override
  Widget build(BuildContext context) {
    final content = _content();
    if (!widget.interactive || _closed) return content;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedWidth && constraints.hasBoundedHeight) {
          _reportSize(
            constraints.biggest,
            MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0,
          );
        }
        return Focus(
          focusNode: _focusNode,
          autofocus: widget.autofocus,
          onKeyEvent: _onKeyEvent,
          onFocusChange: (focused) {
            if (!focused) _run(() => widget.surface.setFocus(false));
          },
          child: MouseRegion(
            cursor: mouseCursorFor(_cursor),
            onExit: (event) => _pointer(
              PointerKind.leave,
              event.localPosition,
              buttons: event.buttons,
            ),
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerUp: _onPointerUp,
              onPointerMove: (event) => _pointer(
                PointerKind.move,
                event.localPosition,
                buttons: event.buttons,
              ),
              onPointerHover: (event) =>
                  _pointer(PointerKind.move, event.localPosition),
              onPointerSignal: _onPointerSignal,
              onPointerPanZoomUpdate: _onPanZoomUpdate,
              child: SizedBox.expand(child: content),
            ),
          ),
        );
      },
    );
  }
}
