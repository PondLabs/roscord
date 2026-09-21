import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:commet/browser_runtime.dart';
import 'package:commet/client/components/widgets/widget_component.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_capabilities_manager.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_component.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_message_handler.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_transport.dart';
import 'package:commet/client/matrix/matrix_client.dart';
import 'package:commet/client/matrix/matrix_room.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/utils/color_utils.dart';
import 'package:commet/utils/notifying_list.dart';
import 'package:flutter/material.dart';

/// The origin used by the old widget runner when it delivered app messages.
/// It remains the app-side origin even when the page itself is hosted directly
/// by CEF instead of by an iframe wrapper.
const String matrixWidgetAppOrigin = 'commet://widget';

/// Matrix protocol messages are transported as script envelopes.  Keeping a
/// dedicated channel means the BrowserRuntime host only sees generic script
/// values and never needs to know Matrix action or capability names.
const String matrixWidgetScriptChannel = 'chat.commet.matrix_widget';

/// These names are part of the existing widget bridge contract.  Do not
/// replace them with a new transport-specific vocabulary.
const String matrixWidgetFromWidgetStoragePrefix = 'chat.commet.fromWidget:';
const String matrixWidgetToWidgetStoragePrefix = 'chat.commet.toWidget:';

/// Generic BrowserRuntime operation names used by the adapter-owned bridge.
/// The CEF host treats these as opaque script values; it does not parse Matrix
/// actions or capability names.
const String matrixWidgetBridgeInstallOperation = 'evaluate_javascript';
const String matrixWidgetBridgeMessageOperation = 'dispatch_script_message';
const int matrixWidgetBridgeProtocolVersion = 1;

/// Installs the compatibility bridge in the opened page.
///
/// The bridge is the BrowserRuntime equivalent of `widgets_ipc.js` plus the
/// old Rust `call_ipc.js` fallback. It keeps the session-storage rendezvous,
/// recursive binary values, iframe postMessage shape, and newline-delimited
/// payloads in the adapter-owned JavaScript contract. The host only needs to
/// expose the generic `__roscordBrowserRuntimeSend` callback and evaluate this
/// script; it never needs Matrix protocol knowledge.
const String matrixWidgetBridgeScript = r'''
(() => {
  if (window.__roscordMatrixWidgetBridgeInstalled) return;

  const APP_ORIGIN = "commet://widget";
  const FROM_PREFIX = "chat.commet.fromWidget:";
  const TO_PREFIX = "chat.commet.toWidget:";
  const BRIDGE_EVENT = "roscord-browser-runtime-widget-message";
  let outboundNumber = 0;

  function arrayBufferToBase64(buffer) {
    const bytes = new Uint8Array(buffer);
    let binary = "";
    const chunkSize = 0x8000;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
  }

  function base64ToArrayBuffer(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  async function encodeArrayBuffers(input) {
    if (input instanceof Blob) {
      return {
        __type: "Blob",
        data: arrayBufferToBase64(await input.arrayBuffer()),
      };
    }
    if (input instanceof ArrayBuffer) {
      return { __type: "ArrayBuffer", data: arrayBufferToBase64(input) };
    }
    if (ArrayBuffer.isView(input)) {
      return {
        __type: "ArrayBuffer",
        data: arrayBufferToBase64(input.buffer),
      };
    }
    if (Array.isArray(input)) {
      return await Promise.all(input.map(encodeArrayBuffers));
    }
    if (input !== null && typeof input === "object") {
      const result = {};
      for (const key of Object.keys(input)) {
        result[key] = await encodeArrayBuffers(input[key]);
      }
      return result;
    }
    return input;
  }

  async function decodeArrayBuffers(input) {
    if (Array.isArray(input)) {
      return await Promise.all(input.map(decodeArrayBuffers));
    }
    if (input !== null && typeof input === "object") {
      if (input.__type === "ArrayBuffer" && typeof input.data === "string") {
        return base64ToArrayBuffer(input.data);
      }
      if (input.__type === "Blob" && typeof input.data === "string") {
        return new Blob([base64ToArrayBuffer(input.data)]);
      }
      const result = {};
      for (const key of Object.keys(input)) {
        result[key] = await decodeArrayBuffers(input[key]);
      }
      return result;
    }
    return input;
  }

  function sendEncoded(encoded) {
    const message = JSON.stringify(encoded);
    const storageKey = FROM_PREFIX + (++outboundNumber).toString();
    const payload = "_" + message + "\n";
    sessionStorage.setItem(storageKey, payload);
    const envelope = {
      storage_key: storageKey,
      payload: payload,
      newline_delimited: true,
      origin: window.location.origin,
      channel: "chat.commet.matrix_widget",
      request_id: storageKey,
    };

    // BrowserRuntime host bridge. Keep the old Rust/Wry IPC shape as the
    // fallback for retained subprocess callers.
    try {
      if (typeof window.__roscordBrowserRuntimeSend === "function") {
        window.__roscordBrowserRuntimeSend(JSON.stringify(envelope));
      } else if (window.ipc && typeof window.ipc.postMessage === "function") {
        window.ipc.postMessage(JSON.stringify({
          type: "Widget",
          data: JSON.stringify({ type: "PostMessage", message: message }),
        }));
      } else {
        window.dispatchEvent(new CustomEvent(BRIDGE_EVENT, { detail: envelope }));
      }
    } finally {
      sessionStorage.removeItem(storageKey);
    }
  }

  function sendIpc(message) {
    encodeArrayBuffers(message).then(sendEncoded);
  }

  const parent = window.parent;
  parent.postMessage = (message, targetOrigin) => {
    if (targetOrigin !== "*" && targetOrigin !== APP_ORIGIN) return;
    sendIpc(message);
  };

  const originalAddEventListener = window.addEventListener.bind(window);
  const messageListeners = [];
  window.addEventListener = (type, callback, options) => {
    if (type === "message") {
      messageListeners.push(callback);
    } else {
      originalAddEventListener(type, callback, options);
    }
  };

  // Called by the generic host for an app-to-page script message.
  window.__roscordBrowserRuntimeReceive = async (envelope) => {
    const storageKey = envelope && envelope.storage_key;
    const payload = envelope && envelope.payload !== undefined
      ? envelope.payload
      : envelope;
    if (storageKey && typeof payload === "string") {
      sessionStorage.setItem(storageKey, payload);
    }
    try {
      const text = typeof payload === "string" && payload.startsWith("_")
        ? payload.substring(1)
        : payload;
      const value = await decodeArrayBuffers(JSON.parse(text));
      const event = { origin: APP_ORIGIN, data: value, source: window };
      if (typeof window.onmessage === "function") window.onmessage(event);
      for (const callback of messageListeners) callback(event);
    } finally {
      if (storageKey) sessionStorage.removeItem(storageKey);
    }
  };

  window.__roscordMatrixWidgetBridgeInstalled = {
    version: 1,
    fromWidgetPrefix: FROM_PREFIX,
    toWidgetPrefix: TO_PREFIX,
  };
})();
''';

/// Immutable caller data used to open one Matrix widget surface.
///
/// This is deliberately independent of Flutter and Matrix model objects so
/// URL/policy construction can be tested at the BrowserRuntime seam.  The
/// [profileKey] must be the stable local account-record identity
/// (`MatrixClient.identifier`), not a Matrix user id or homeserver URL.
class MatrixWidgetAdapterLaunch {
  final String widgetUrl;
  final String widgetId;
  final String accountId;
  final String profileKey;
  final String matrixUserId;
  final String matrixRoomId;
  final String matrixDisplayName;
  final String matrixDeviceId;
  final String matrixBaseUrl;
  final String colorSchemeJson;
  final String theme;
  final PresentationMode presentation;
  final PrivacyMode privacy;
  final String parentUrl;

  /// Matrix capability names stay in Dart and are handled by the existing
  /// capability manager; they are never copied into cef_host policy data.
  final Map<String, bool> capabilities;

  /// Optional host-facing policy flags use only generic BrowserRuntime names.
  final Map<String, bool> hostCapabilities;

  MatrixWidgetAdapterLaunch({
    required this.widgetUrl,
    required this.widgetId,
    required this.accountId,
    required this.profileKey,
    required this.matrixUserId,
    required this.matrixRoomId,
    required this.matrixDisplayName,
    required this.matrixDeviceId,
    required this.matrixBaseUrl,
    required this.colorSchemeJson,
    required this.theme,
    required this.presentation,
    required this.privacy,
    this.parentUrl = matrixWidgetAppOrigin,
    Map<String, bool> capabilities = const {},
    Map<String, bool> hostCapabilities = const {},
  })  : capabilities = Map.unmodifiable(capabilities),
        hostCapabilities = Map.unmodifiable(hostCapabilities) {
    _requireNonEmpty(widgetUrl, 'widgetUrl');
    _requireNonEmpty(widgetId, 'widgetId');
    _requireNonEmpty(accountId, 'accountId');
    _requireNonEmpty(profileKey, 'profileKey');
    _requireNonEmpty(matrixUserId, 'matrixUserId');
    _requireNonEmpty(matrixRoomId, 'matrixRoomId');
    _requireNonEmpty(matrixDeviceId, 'matrixDeviceId');
    _requireNonEmpty(matrixBaseUrl, 'matrixBaseUrl');
    _requireNonEmpty(theme, 'theme');
    _requireNonEmpty(parentUrl, 'parentUrl');

    // Validate the opaque key at the adapter boundary, before it reaches the
    // host or any generated profile path.
    ProfileKey(profileKey);
  }

  /// Builds the adapter input from the existing Matrix caller models.  The
  /// account record identifier is deliberately used for both `accountId` and
  /// `profileKey`; user ids and homeserver URLs are not stable profile keys.
  factory MatrixWidgetAdapterLaunch.fromMatrixWidget({
    required MatrixUserWidgetInfo info,
    required MatrixRoom room,
    required ColorScheme colorScheme,
    required Brightness brightness,
    PresentationMode presentation = PresentationMode.embedded,
    PrivacyMode privacy = PrivacyMode.persistent,
    Map<String, bool> capabilities = const {},
  }) {
    final client = room.client as MatrixClient;
    final self = client.self;
    final deviceId = client.matrixClient.deviceID;
    if (self == null || deviceId == null) {
      throw StateError('Matrix widget requires a signed-in account/device');
    }
    return MatrixWidgetAdapterLaunch(
      widgetUrl: info.url,
      widgetId: info.id,
      accountId: client.identifier,
      profileKey: client.identifier,
      matrixUserId: self.identifier,
      matrixRoomId: room.identifier,
      matrixDisplayName: self.displayName,
      matrixDeviceId: deviceId,
      matrixBaseUrl: client.matrixClient.baseUri.toString(),
      colorSchemeJson: jsonEncode(colorScheme.toJson()),
      theme: brightness == Brightness.light ? 'light' : 'dark',
      presentation: presentation,
      privacy: privacy,
      capabilities: capabilities,
    );
  }

  /// URL with all legacy Matrix substitutions and bridge metadata applied.
  Uri get initialUrl => MatrixWidgetAdapter.buildWidgetUri(this);

  /// BrowserRuntime declaration for this surface.  The host receives only
  /// typed policy/profile values; Matrix protocol details stay in this Dart
  /// adapter and its script bridge.
  SurfaceSpec toSurfaceSpec() {
    final url = initialUrl.toString();
    final origins = <String>{};
    final initialOrigin = _originOf(url);
    final parentOrigin = _originOf(parentUrl);
    if (initialOrigin != null) origins.add(initialOrigin);
    if (parentOrigin != null) origins.add(parentOrigin);

    return SurfaceSpec(
      profileKey: ProfileKey(profileKey),
      presentation: presentation,
      privacy: privacy,
      initialNavigation: NavigationRequest(url: url),
      policy: SurfacePolicy(
        allowedOrigins: origins.cast<String>(),
        capabilities: hostCapabilities,
      ),
    );
  }
}

/// A BrowserRuntime-backed Matrix widget transceiver.
///
/// The old in-app runner used sessionStorage as a rendezvous for large
/// messages and newline-delimited stdout for the subprocess runner.  The
/// adapter keeps both observable parts of that contract: each envelope names
/// a `chat.commet.fromWidget:*`/`chat.commet.toWidget:*` key and its payload is
/// a single newline-delimited UTF-8 stream.  BrowserRuntime only carries the
/// generic script envelope.
class MatrixWidgetBrowserRuntimeTransceiver implements WidgetTransceiver {
  final BrowserRuntime runtime;
  final SurfaceId surfaceId;
  final ProfileKey profileKey;
  final String pageOrigin;
  final String appOrigin;

  final StreamController<Uint8List> _received =
      StreamController<Uint8List>.broadcast();
  final List<int> _incomingBuffer = <int>[];
  late final StreamSubscription<SurfaceEvent> _eventsSubscription;

  Future<void> _commandTail = Future<void>.value();
  int _nextCommandSequence = 1;
  int _nextMessageNumber = 1;
  bool _disposed = false;
  bool _bridgeInitialized = false;

  MatrixWidgetBrowserRuntimeTransceiver({
    required this.runtime,
    required this.surfaceId,
    required this.profileKey,
    required this.pageOrigin,
    this.appOrigin = matrixWidgetAppOrigin,
  }) {
    _eventsSubscription = runtime.events().listen(_handleEvent);
  }

  @override
  Stream<Uint8List> get onReceived => _received.stream;

  /// Last command sequence allocated by this transport.  Exposed for tests
  /// and diagnostics, while callers still use the WidgetTransceiver seam.
  int get lastCommandSequence => _nextCommandSequence - 1;

  /// Installs the adapter-owned JavaScript/session-storage bridge in the page.
  /// The operation is generic at the BrowserRuntime boundary; Matrix protocol
  /// actions remain in the Dart message and capability handlers.
  Future<void> initializeBridge() async {
    if (_disposed || _bridgeInitialized) return;
    try {
      await _enqueueCommand(
        ScriptEnvelope(
          source: ScriptSource.app,
          origin: appOrigin,
          channel: matrixWidgetScriptChannel,
          requestId: 'matrix-widget-bridge-install',
          value: {
            'operation': matrixWidgetBridgeInstallOperation,
            'protocol_version': matrixWidgetBridgeProtocolVersion,
            'script': matrixWidgetBridgeScript,
            'app_origin': appOrigin,
          },
        ),
      );
      _bridgeInitialized = true;
    } catch (error, stack) {
      _bridgeInitialized = false;
      Log.onError(error, stack, content: 'Installing Matrix widget bridge');
      rethrow;
    }
  }

  @override
  void send(Uint8List data) {
    if (_disposed) return;

    final messageNumber = _nextMessageNumber++;
    final storageKey = '$matrixWidgetToWidgetStoragePrefix$messageNumber';
    final payload = '_${utf8.decode(data)}\n';
    final envelope = ScriptEnvelope(
      source: ScriptSource.app,
      origin: appOrigin,
      channel: matrixWidgetScriptChannel,
      requestId: 'matrix-widget-to-page-$messageNumber',
      value: {
        'operation': matrixWidgetBridgeMessageOperation,
        'storage_key': storageKey,
        'payload': payload,
        'newline_delimited': true,
      },
    );
    unawaited(
      _enqueueCommand(envelope).then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ),
    );
  }

  Future<void> _enqueueCommand(ScriptEnvelope envelope) {
    final command = ScriptCommand(
      sequence: _nextCommandSequence++,
      profileKey: profileKey,
      envelope: envelope,
    );

    // WidgetMessageTransport.send is intentionally fire-and-forget.  Queue
    // commands here so the BrowserRuntime's ordered-command invariant is
    // maintained even when a page emits a burst of messages.
    final commandFuture = _commandTail.then<void>(
      (_) => runtime.command(surfaceId, command),
    );
    _commandTail = commandFuture.then<void>((_) {},
        onError: (Object error, StackTrace stack) {
      Log.onError(error, stack, content: 'Matrix widget BrowserRuntime send');
    });
    return commandFuture;
  }

  void _handleEvent(SurfaceEvent event) {
    if (_disposed || event.surfaceId != surfaceId) return;
    if (event is! ScriptMessageEvent) return;

    final envelope = event.envelope;
    if (envelope.channel != matrixWidgetScriptChannel) return;
    if (envelope.source != ScriptSource.page) {
      return;
    }
    if (!_originMatches(envelope.origin)) {
      Log.w('Ignoring Matrix widget message from an unexpected origin');
      return;
    }

    final value = envelope.value;
    final storageKey = _storageKey(value);
    if (storageKey == null ||
        !storageKey.startsWith(matrixWidgetFromWidgetStoragePrefix)) {
      return;
    }

    final payload = _payload(value);
    if (payload == null || !payload.startsWith('_')) return;

    _incomingBuffer.addAll(utf8.encode(payload.substring(1)));
    _drainMessages();
  }

  bool _originMatches(String origin) {
    return origin == pageOrigin || origin == appOrigin;
  }

  String? _storageKey(Object? value) {
    if (value is! Map) return null;
    final key = value['storage_key'] ?? value['storageKey'];
    return key is String ? key : null;
  }

  String? _payload(Object? value) {
    if (value is! Map) return null;
    final payload = value['payload'];
    if (payload is String) return payload;
    if (payload is Uint8List) return utf8.decode(payload);
    if (payload is BrowserRuntimeBlob) return utf8.decode(payload.bytes);
    return null;
  }

  void _drainMessages() {
    while (true) {
      final separator = _incomingBuffer.indexOf(0x0a);
      if (separator < 0) return;
      final message = _incomingBuffer.sublist(0, separator);
      _incomingBuffer.removeRange(0, separator + 1);
      if (message.isNotEmpty) {
        _received.add(Uint8List.fromList(message));
      }
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _commandTail;
    await _eventsSubscription.cancel();
    await _received.close();
  }
}

/// One opened BrowserRuntime surface and its Matrix script transport.
///
/// Keeping this lifecycle object separate from the Flutter-facing runner lets
/// presentation code open/close a surface without importing Matrix model
/// classes, and gives the adapter a deterministic one-active-session seam.
class MatrixWidgetBrowserRuntimeSession {
  final BrowserRuntime runtime;
  final SurfaceId surfaceId;
  final ProfileKey profileKey;
  final MatrixWidgetBrowserRuntimeTransceiver transceiver;

  final StreamController<SurfaceEvent> _events =
      StreamController<SurfaceEvent>.broadcast();
  final StreamController<void> _onClosed = StreamController<void>.broadcast();
  final Completer<void> _closed = Completer<void>();
  final Completer<void> _ready = Completer<void>();
  Object? _readyFailure;
  late final StreamSubscription<SurfaceEvent> _runtimeSubscription;

  Future<void>? _disposeFuture;
  bool _closedState = false;

  MatrixWidgetBrowserRuntimeSession({
    required this.runtime,
    required this.surfaceId,
    required this.profileKey,
    required String pageOrigin,
  }) : transceiver = MatrixWidgetBrowserRuntimeTransceiver(
          runtime: runtime,
          surfaceId: surfaceId,
          profileKey: profileKey,
          pageOrigin: pageOrigin,
        ) {
    _runtimeSubscription = runtime.events().listen(_handleEvent);
  }

  Stream<SurfaceEvent> get events => _events.stream;

  Stream<void> get onClosed => _onClosed.stream;

  Future<void> initialize() async {
    await waitUntilReady();
    await transceiver.initializeBridge();
  }

  Future<void> waitUntilReady() async {
    final failure = _readyFailure;
    if (failure != null) throw failure;
    if (_closedState && !_ready.isCompleted) {
      throw StateError('Matrix widget surface closed before ready');
    }
    await _ready.future;
    final readyFailure = _readyFailure;
    if (readyFailure != null) throw readyFailure;
  }

  void _handleEvent(SurfaceEvent event) {
    if (event.surfaceId != surfaceId || _closedState) return;
    _events.add(event);
    if (event is ReadyEvent) {
      if (!_ready.isCompleted) _ready.complete();
    } else if (event is FailedEvent) {
      if (!_ready.isCompleted) {
        _readyFailure = StateError(event.failure.message);
      }
      _finishClosed();
    } else if (event is ClosedEvent) {
      if (!_ready.isCompleted) {
        _readyFailure = StateError('Matrix widget surface closed before ready');
      }
      _finishClosed();
    }
  }

  void _finishClosed() {
    if (_closedState) return;
    _closedState = true;
    if (!_ready.isCompleted) {
      _readyFailure ??= StateError('Matrix widget surface closed before ready');
      _ready.complete();
    }
    if (!_closed.isCompleted) _closed.complete();
    _onClosed.add(null);
    _onClosed.close();
    _events.close();
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final future = _disposeInternal();
    _disposeFuture = future;
    return future;
  }

  Future<void> _disposeInternal() async {
    if (!_closedState) {
      try {
        await runtime.close(surfaceId);
        await _closed.future.timeout(
          const Duration(seconds: 5),
          onTimeout: _finishClosed,
        );
      } on Object catch (error, stack) {
        Log.onError(error, stack, content: 'Closing Matrix widget surface');
        _finishClosed();
      }
    }
    await transceiver.dispose();
    await _runtimeSubscription.cancel();
    if (!_events.isClosed) await _events.close();
    if (!_onClosed.isClosed) await _onClosed.close();
  }
}

/// MatrixWidgetRunner implementation for one BrowserRuntime surface.
class MatrixWidgetBrowserRuntimeRunner implements MatrixWidgetRunner {
  @override
  final MatrixRoom? room;

  @override
  final MatrixClient client;

  @override
  final String widgetId;

  @override
  final UserWidgetInfo info;

  @override
  late final WidgetMessageTransport messageTransport;

  @override
  late final WidgetEventHandler eventHandler;

  @override
  late final WidgetCapabilityManager capabilities;

  @override
  final NotifyingList<LogEntry> logs = NotifyingList.empty(growable: true);

  final MatrixWidgetBrowserRuntimeSession session;
  late final StreamSubscription<SurfaceEvent> _sessionSubscription;
  bool _closedState = false;

  BrowserRuntime get runtime => session.runtime;

  SurfaceId get surfaceId => session.surfaceId;

  ProfileKey get profileKey => session.profileKey;

  MatrixWidgetBrowserRuntimeTransceiver get transceiver => session.transceiver;

  /// Keeps the runner bound to its own transceiver so a second listener cannot
  /// consume the same script message stream.
  MatrixWidgetBrowserRuntimeRunner._bound({
    required this.session,
    required this.room,
    required this.client,
    required this.widgetId,
    required this.info,
    required BuildContext context,
  }) {
    messageTransport = MatrixWidgetTransport(session.transceiver);
    eventHandler = MatrixWidgetMessageHandler(runner: this);
    capabilities = MatrixWidgetCapabilitiesManager(
      runner: this,
      context: context,
    );
    _sessionSubscription = session.events.listen(_handleRuntimeEvent);
  }

  /// Surface events are intentionally additive to the WidgetRunner protocol;
  /// presenters can subscribe without learning about Matrix message actions.
  Stream<SurfaceEvent> get surfaceEvents => session.events;

  @override
  Stream<void> get onClosed => session.onClosed;

  void _handleRuntimeEvent(SurfaceEvent event) {
    if (_closedState) return;
    if (event is FailedEvent) {
      logs.add(LogEntry(LogType.error, event.failure.message));
      _finishClosed();
    } else if (event is ClosedEvent) {
      _finishClosed();
    }
  }

  void _finishClosed() {
    if (_closedState) return;
    _closedState = true;
  }

  @override
  Future<void> dispose() async {
    await session.dispose();
    await _sessionSubscription.cancel();
  }
}

/// Adapter that owns the one active Matrix widget session for a runtime.
class MatrixWidgetAdapter {
  final BrowserRuntime runtime;
  MatrixWidgetBrowserRuntimeSession? _activeSession;
  MatrixWidgetBrowserRuntimeRunner? _activeRunner;
  Future<void> _openTail = Future<void>.value();

  MatrixWidgetAdapter({required this.runtime});

  MatrixWidgetBrowserRuntimeRunner? get activeRunner => _activeRunner;

  MatrixWidgetBrowserRuntimeSession? get activeSession => _activeSession;

  /// Opens a transport session without requiring Flutter or Matrix model
  /// objects. Presentation issues use this seam to attach their own renderer.
  Future<MatrixWidgetBrowserRuntimeSession> openSession(
    MatrixWidgetAdapterLaunch launch,
  ) {
    final result = _openTail.then((_) => _openSession(launch));
    // Keep the queue usable after a failed open while returning the original
    // error to that caller.
    _openTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<MatrixWidgetBrowserRuntimeSession> _openSession(
    MatrixWidgetAdapterLaunch launch,
  ) async {
    final previous = _activeSession;
    if (previous != null) await previous.dispose();
    _activeSession = null;
    _activeRunner = null;

    final surfaceId = await runtime.open(launch.toSurfaceSpec());
    final session = MatrixWidgetBrowserRuntimeSession(
      runtime: runtime,
      surfaceId: surfaceId,
      profileKey: ProfileKey(launch.profileKey),
      pageOrigin: _originOf(launch.initialUrl.toString()) ?? '',
    );
    try {
      await session.initialize();
    } catch (_) {
      await session.dispose();
      rethrow;
    }
    _activeSession = session;
    session.onClosed.listen((_) {
      if (identical(_activeSession, session)) _activeSession = null;
    });
    return session;
  }

  /// Opens a new surface after deterministically disposing the previous one.
  Future<MatrixWidgetBrowserRuntimeRunner> open({
    required MatrixWidgetAdapterLaunch launch,
    required MatrixRoom room,
    required MatrixClient client,
    required UserWidgetInfo info,
    required BuildContext context,
  }) async {
    final session = await openSession(launch);
    final runner = MatrixWidgetBrowserRuntimeRunner._bound(
      session: session,
      room: room,
      client: client,
      widgetId: launch.widgetId,
      info: info,
      context: context,
    );
    _activeRunner = runner;
    runner.onClosed.listen((_) {
      if (identical(_activeRunner, runner)) _activeRunner = null;
    });
    return runner;
  }

  Future<void> dispose() async {
    await _openTail;
    final session = _activeSession;
    if (session != null) await session.dispose();
    _activeSession = null;
    _activeRunner = null;
  }

  static Uri buildWidgetUri(MatrixWidgetAdapterLaunch launch) {
    var url = Uri.encodeFull(launch.widgetUrl);
    final replacements = <String, String>{
      r'$matrix_user_id': launch.matrixUserId,
      r'$matrix_room_id': launch.matrixRoomId,
      r'$matrix_display_name': launch.matrixDisplayName,
      r'$org.matrix.msc3819.matrix_device_id': launch.matrixDeviceId,
      r'$org.matrix.msc4039.matrix_base_url': launch.matrixBaseUrl,
      r'$chat.commet.color_scheme': Uri.encodeComponent(launch.colorSchemeJson),
      r'$org.matrix.msc2873.client_theme': launch.theme,
    };
    for (final entry in replacements.entries) {
      url = url.replaceAll(entry.key, entry.value);
    }

    final uri = Uri.parse(url);
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        'parentUrl': launch.parentUrl,
        'widgetId': launch.widgetId,
        'accountId': launch.accountId,
        'profileKey': launch.profileKey,
      },
    );
  }
}

String? _originOf(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) return null;
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port';
}

void _requireNonEmpty(String value, String name) {
  if (value.isEmpty)
    throw ArgumentError.value(value, name, 'must not be empty');
}
