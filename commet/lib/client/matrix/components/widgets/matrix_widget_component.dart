import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:commet/browser_runtime.dart';
import 'package:commet/client/client.dart';
import 'package:commet/client/components/widgets/widget_component.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_adapter.dart';
import 'package:commet/client/matrix/components/widgets/runners/android_activity/matrix_widget_android_runner.dart';
import 'package:commet/client/matrix/components/widgets/runners/in_app_web_view/matrix_widget_inappwebview_runner.dart';
import 'package:commet/client/matrix/components/widgets/runners/remote_http/self_signed_https_server.dart';
import 'package:commet/client/matrix/components/widgets/runners/remote_http/matrix_widget_remote_http_runner.dart';
import 'package:commet/client/matrix/matrix_client.dart';
import 'package:commet/client/matrix/matrix_mxc_image_provider.dart';
import 'package:commet/client/matrix/matrix_room.dart';
import 'package:commet/client/room.dart';
import 'package:commet/config/app_config.dart';
import 'package:commet/config/platform_utils.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/main.dart';
import 'package:commet/ui/organisms/overlay_windows/overlay_window_manager.dart';
import 'package:commet/utils/color_utils.dart';
import 'package:commet/utils/error_utils.dart';
import 'package:commet/utils/image_or_icon.dart';
import 'package:commet/utils/links/link_utils.dart';
import 'package:dart_ipc/dart_ipc.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' show StrippedStateEvent;
import 'package:matrix/matrix_api_lite/utils/try_get_map_extension.dart';
import 'package:network_info_plus/network_info_plus.dart';

/// Whether desktop Matrix widgets route through the CEF [MatrixWidgetAdapter]
/// instead of a legacy runner.
///
/// Pure predicate over platform flags so it is unit-testable: Windows and
/// Linux use the bundled CEF runtime unconditionally after the cutover. Web,
/// Android, macOS, and iOS keep their existing runners; there is no legacy,
/// system, or unowned-browser branch left on desktop.
bool matrixWidgetUsesCef({
  required bool isWeb,
  required bool isWindows,
  required bool isLinux,
}) =>
    !isWeb && (isWindows || isLinux);

class MatrixUserWidgetInfo implements UserWidgetInfo {
  late String _name;

  StrippedStateEvent event;

  String roomId;

  MatrixUserWidgetInfo({
    required this.id,
    required String name,
    required this.url,
    required this.type,
    required this.icon,
    required this.roomId,
    required this.event,
  }) {
    _name = name;
  }

  @override
  String get name => _name;

  @override
  String url;

  @override
  String type;

  String id;

  @override
  ImageOrIcon icon;

  @override
  String get namespace => "${roomId}_${id}_${event.senderId}_${url}";

  @override
  String get senderId => event.senderId;
}

abstract class MatrixWidgetRunner
    extends WidgetRunner<MatrixClient, MatrixRoom> {}

class MatrixWidgetComponent implements WidgetComponent<MatrixClient> {
  @override
  MatrixClient client;

  MatrixWidgetComponent(this.client);

  @override
  List<UserWidgetInfo> getWidgets(Room room) {
    var mx = (room as MatrixRoom).matrixRoom;
    var states = mx.states["im.vector.modular.widgets"];
    if (states == null) return List.empty();

    var result = List<MatrixUserWidgetInfo>.empty(growable: true);

    for (var s in states.entries) {
      String? id = s.value.content.tryGet("id") ?? s.key;
      String? url = s.value.content.tryGet("url");
      String? type = s.value.content.tryGet("type");
      String? name = s.value.content.tryGet("name");
      String? avatarUrl = s.value.content.tryGet("avatar_url");

      if (url == null || type == null || name == null) continue;

      var icon = ImageOrIcon(icon: Icons.widgets);

      if (avatarUrl != null) {
        var uri = Uri.tryParse(avatarUrl);
        if (uri?.scheme == "mxc") {
          icon.image = MatrixMxcImage(uri!, client.matrixClient);
        }
      }

      // https://github.com/element-hq/element-web/blob/cd8a1012c82be10178fb134ef8a791eef217b4c9/apps/web/src/components/views/avatars/WidgetAvatar.tsx#L26
      if (type.contains("jitsi")) {
        icon.icon = Icons.video_call;
      } else if (type.contains("meeting") || type.contains("calendar")) {
        icon.icon = Icons.calendar_month;
      } else if (type.contains("doc") ||
          type.contains("pad") ||
          type.contains("calc")) {
        icon.icon = Icons.edit_document;
      } else if (type.contains("clock")) {
        icon.icon = Icons.timer;
      }

      url = Uri.encodeFull(url);

      result.add(MatrixUserWidgetInfo(
          id: id,
          name: name,
          url: url,
          type: type,
          roomId: room.identifier,
          event: s.value,
          icon: icon));
    }

    return result;
  }

  void registerRunner(MatrixWidgetRunner runner) {
    Log.i("Registering Matrix Widget Runner: $runner");

    WidgetComponent.currentSessions.add(runner);

    runner.onClosed
        .listen((_) => WidgetComponent.currentSessions.remove(runner));
  }

  @override
  WidgetHostType get defaultHostType {
    if (PlatformUtils.isWindows || PlatformUtils.isLinux) {
      return WidgetHostType.embedded;
    }

    if (PlatformUtils.isAndroid) {
      return WidgetHostType.androidActivity;
    }

    if (PlatformUtils.isWeb) {
      return WidgetHostType.embedded;
    }

    return WidgetHostType.embedded;
  }

  @override
  List<WidgetHostType> supportedHostTypes() {
    if (PlatformUtils.isWindows || PlatformUtils.isLinux) {
      return const [
        WidgetHostType.embedded,
        WidgetHostType.standalone,
        WidgetHostType.remoteHttpClient
      ];
    }

    if (PlatformUtils.isAndroid) {
      return const [WidgetHostType.androidActivity, WidgetHostType.embedded];
    }

    if (PlatformUtils.isWeb) {
      return const [WidgetHostType.embedded];
    }

    throw UnimplementedError();
  }

  @override
  Future<void> openWidget(
      UserWidgetInfo widget, Room room, BuildContext context,
      {WidgetHostType? type}) async {
    ErrorUtils.tryRun(context, () async {
      var info = widget as MatrixUserWidgetInfo;
      var url = Uri.encodeFull(info.url);

      var colorScheme = JsonEncoder().convert(ColorScheme.of(context).toJson());
      var replacements = {
        "\$matrix_user_id": room.client.self!.identifier,
        "\$matrix_room_id": room.identifier,
        "\$matrix_display_name": room.client.self!.displayName,
        "\$org.matrix.msc3819.matrix_device_id":
            (room.client as MatrixClient).matrixClient.deviceID!,
        "\$org.matrix.msc4039.matrix_base_url":
            (room.client as MatrixClient).matrixClient.baseUri.toString(),
        "\$chat.commet.color_scheme": Uri.encodeComponent(colorScheme),
        "\$org.matrix.msc2873.client_theme":
            Theme.of(context).brightness == Brightness.light ? "light" : "dark",
      };

      Log.i("Replacements: ${jsonEncode(replacements)}");

      for (var pair in replacements.entries) {
        url = url.replaceAll(pair.key, pair.value);
      }

      var uri = Uri.parse(url);

      uri = Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.port,
          path: uri.path,
          fragment: uri.fragment.isEmpty ? null : uri.fragment,
          queryParameters: {
            ...uri.queryParameters,
            "parentUrl": "commet://widget",
            "widgetId": info.id,
          });

      url = uri.toString();

      Log.i("Launching Widget: $url");

      var runnerType = type ?? defaultHostType;

      switch (runnerType) {
        case WidgetHostType.embedded:
          // Desktop embedded Matrix widgets run unconditionally through the
          // bundled CEF runtime after the cutover; every other platform keeps
          // its existing in-app runner. There is no WebView, Wry, system CEF,
          // or unowned-browser branch left on desktop.
          if (matrixWidgetUsesCef(
            isWeb: PlatformUtils.isWeb,
            isWindows: PlatformUtils.isWindows,
            isLinux: PlatformUtils.isLinux,
          )) {
            await openCefMatrixWidget(
              info,
              widget,
              room,
              context,
              presentation: PresentationMode.embedded,
            );
            return;
          }
          uri = Uri.parse(url);

          // Preserved web/Android/macOS/iOS path: the in-app runner serves
          // from an in-memory page. Desktop Windows/Linux never reach this
          // branch; they open through the CEF adapter above.
          uri = Uri(
              scheme: uri.scheme,
              host: uri.host,
              port: uri.port,
              path: uri.path,
              fragment: uri.fragment.isEmpty ? null : uri.fragment,
              queryParameters: {
                ...uri.queryParameters,
                "parentUrl": "http://localhost/widget",
                "widgetId": info.id,
              });

          url = uri.toString();

          await createEmbeddedWidget(url, info, widget, room, context);
          return;
        case WidgetHostType.standalone:
          // Desktop standalone Matrix widgets open in a roscord-owned CEF
          // window through the same runtime, account context, policy, and
          // permission mediation as embedded. Standalone is only offered on
          // desktop; other platforms never reach this branch.
          await openCefMatrixWidget(
            info,
            widget,
            room,
            context,
            presentation: PresentationMode.standalone,
          );
          return;
        case WidgetHostType.remoteHttpClient:
          await createRemoteHttpWidgetRunner(url, room, widget,
              useInsecureHttp: false, allowRemoteConnection: true);
          return;
        case WidgetHostType.androidActivity:
          uri = Uri(
              scheme: uri.scheme,
              host: uri.host,
              port: uri.port,
              path: uri.path,
              fragment: uri.fragment.isEmpty ? null : uri.fragment,
              queryParameters: {
                ...uri.queryParameters,
                "parentUrl": "http://localhost/widget",
                "widgetId": info.id,
              });

          url = uri.toString();
          createAndroidActivityWidget(url, widget, room, context);
          return;
      }
    });
  }

  Future<void> createAndroidActivityWidget(String url,
      MatrixUserWidgetInfo info, Room room, BuildContext context) async {
    var receiveSocketPath = await AppConfig.getWidgetSocketPath();

    var file = File(receiveSocketPath);

    var bytes =
        (await rootBundle.load("assets/data/widget_runner_android.html"))
            .buffer
            .asUint8List();

    var text = Utf8Decoder().convert(bytes);

    var scriptBytes = (await rootBundle.load("assets/data/widgets_common.js"))
        .buffer
        .asUint8List();
    var scriptText = Utf8Decoder().convert(scriptBytes);

    text =
        text.replaceAll("\$RUNNER_PAGE_TITLE", "roscord Widget | ${info.name}");

    text = text.replaceAll("\$IFRAME_URL", url.toString());
    text = text.replaceAll("\$WIDGET_ID", info.id);

    text = text.replaceAll("//\${WIDGETS_COMMON}", scriptText.toString());

    if (await file.exists()) {
      await file.delete();
    }

    var server = await bind(receiveSocketPath);
    Log.i("Server socket path: ${receiveSocketPath}");
    Log.i("Opened socket: ${server}");

    const platform = const MethodChannel('chat.commet.commetapp/utils');

    await platform.invokeMethod<bool>("openWidgetWindow", {
      "url": url,
      "socket": receiveSocketPath,
      "page": text,
    });

    var runner = MatrixWidgetAndroidRunner(
        room: room as MatrixRoom,
        widgetId: info.id,
        client: room.client as MatrixClient,
        info: info,
        socket: server,
        context: context);

    registerRunner(runner);
  }

  Future<void> createEmbeddedWidget(String url, MatrixUserWidgetInfo info,
      MatrixUserWidgetInfo widget, Room room, BuildContext context,
      {HttpServer? server}) async {
    var bytes =
        (await rootBundle.load("assets/data/widget_runner_embedded.html"))
            .buffer
            .asUint8List();

    var text = Utf8Decoder().convert(bytes);

    var scriptBytes = (await rootBundle.load("assets/data/widgets_common.js"))
        .buffer
        .asUint8List();
    var scriptText = Utf8Decoder().convert(scriptBytes);

    text =
        text.replaceAll("\$RUNNER_PAGE_TITLE", "roscord Widget | ${info.name}");

    text = text.replaceAll("\$IFRAME_URL", url.toString());

    text = text.replaceAll("//\${WIDGETS_COMMON}", scriptText.toString());

    StreamController onExitController = StreamController();

    Log.i("Initial Page:");
    Log.i(text);

    server?.listen((request) async {
      if (request.connectionInfo!.remoteAddress.isLoopback == false) {
        request.response
          ..statusCode = 403
          ..close();
        return;
      }

      var responseBytes = Utf8Encoder().convert(text);
      Log.i("Handling request");
      await request.response
        ..headers.contentType = new ContentType("text", "html")
        ..headers.contentLength = responseBytes.length
        ..statusCode = 200
        ..add(responseBytes)
        ..close();

      Log.i("Handled initial request, closing server");
      server.close();
    });

    var builtWidget = MatrixWidgetInappwebviewRunnerWidget(
        info: info,
        widgetId: widget.id,
        initialPageData: text,
        onExitController: onExitController,
        room: room as MatrixRoom,
        server: server,
        component: this);

    var window = OverlayWindow(
        widget: builtWidget,
        title: info.name,
        onClose: onExitController.stream);

    OverlayWindowsManager.of(context).addWindow(window);
  }

  /// Opens a desktop Matrix widget through the bundled CEF runtime.
  ///
  /// Unconditional after the cutover: Windows and Linux embedded and
  /// standalone presentations share one lazily started host, one account
  /// request context, one policy, and one permission mediation. There is no
  /// validation switch, no legacy runner, and no fallback engine.
  Future<void> openCefMatrixWidget(
    MatrixUserWidgetInfo info,
    MatrixUserWidgetInfo widget,
    Room room,
    BuildContext context, {
    required PresentationMode presentation,
  }) async {
    final runtime = browserRuntime;
    if (runtime == null) {
      throw StateError('Embedded browser unavailable on this platform');
    }
    final matrixRoom = room as MatrixRoom;
    final launch = MatrixWidgetAdapterLaunch.fromMatrixWidget(
      info: info,
      room: matrixRoom,
      colorScheme: ColorScheme.of(context),
      brightness: Theme.of(context).brightness,
      presentation: presentation,
    );
    final adapter = MatrixWidgetAdapter(runtime: runtime);
    final runner = await adapter.open(
      launch: launch,
      room: matrixRoom,
      client: room.client as MatrixClient,
      info: info,
      context: context,
    );
    registerRunner(runner);

    final onExitController = StreamController();
    runner.onClosed.listen((_) {
      if (!onExitController.isClosed) onExitController.add(null);
    });

    final builtWidget = _CefMatrixWidget(
      component: this,
      adapter: adapter,
      runner: runner,
      launch: launch,
      presentation: presentation,
      onExitController: onExitController,
    );

    final window = OverlayWindow(
        widget: builtWidget,
        title: info.name,
        onClose: onExitController.stream);

    OverlayWindowsManager.of(context).addWindow(window);
  }

  Future<void> createRemoteHttpWidgetRunner(
      String url, Room room, MatrixUserWidgetInfo widget,
      {bool useInsecureHttp = false,
      bool allowRemoteConnection = false}) async {
    final info = NetworkInfo();

    var ip = await info.getWifiIP();

    Log.i("Got IP: $ip");

    if (ip == null) {
      var interfaces = await NetworkInterface.list();
      var interface = interfaces.firstOrNull;
      var address = interface?.addresses.firstOrNull;

      ip = address?.address;
    }

    Log.i("Got IP: $ip");

    // Preserved remote-device flow only: the client connects from another
    // device via QR/link. There is no local system-browser branch anymore.
    HttpServer? server;
    if (useInsecureHttp) {
      server = await spawnServerWithOpenPort();
    } else {
      server = await spawnSelfSignedHttpsServer(ip!);
    }

    Log.i("Hosted server: ${ip}");

    var runner = MatrixUserWidgetRemoteHttpRunner(
        room: room as MatrixRoom,
        widgetId: widget.id,
        client: client,
        url: url,
        info: widget,
        server: server,
        allowRemoteConnection: allowRemoteConnection,
        context: navigator.currentContext!,
        useInsecureHttp: useInsecureHttp,
        hostName: ip!);

    registerRunner(runner);
  }
}

/// Desktop Matrix widget presentation through the bundled CEF runtime.
///
/// Replaces the deleted legacy branches (in-app web view and Wry
/// child-process) on Windows and Linux: the adapter launch opens as an
/// embedded [BrowserRuntime] surface shown in
/// normal Flutter composition, or as a standalone surface in a roscord-owned
/// window. The provider allowlist and navigation policy travel in the
/// [SurfaceSpec]; disallowed links become explicit external actions via
/// `LinkUtils`, and closing the overlay closes the surface so no profile,
/// host, or owned-window leaks. Loading, Retry, Close, and error chrome
/// match the other CEF surfaces. Web, Android, macOS, and iOS never reach
/// this widget (see [matrixWidgetUsesCef]).
class _CefMatrixWidget extends StatefulWidget {
  const _CefMatrixWidget({
    required this.component,
    required this.adapter,
    required this.runner,
    required this.launch,
    required this.presentation,
    required this.onExitController,
  });

  final MatrixWidgetComponent component;
  final MatrixWidgetAdapter adapter;
  final MatrixWidgetBrowserRuntimeRunner runner;
  final MatrixWidgetAdapterLaunch launch;
  final PresentationMode presentation;
  final StreamController onExitController;

  @override
  State<_CefMatrixWidget> createState() => _CefMatrixWidgetState();
}

class _CefMatrixWidgetState extends State<_CefMatrixWidget> {
  late MatrixWidgetAdapter _adapter;
  EmbeddedBrowserSurface? _embeddedSurface;
  StandaloneBrowserSurface? _standaloneSurface;
  StreamSubscription<SurfaceEvent>? _eventSubscription;
  StreamSubscription<void>? _closedSubscription;
  Object? _error;
  int _revision = 0;
  Size? _lastSize;
  final FocusNode _focusNode = FocusNode(debugLabel: 'CefMatrixWidget');

  BrowserRuntime? get _runtime => browserRuntime;

  late final MatrixRoom _room;
  late final MatrixClient _client;
  late final UserWidgetInfo _info;

  @override
  void initState() {
    super.initState();
    _adapter = widget.adapter;
    _room = widget.runner.room as MatrixRoom;
    _client = widget.runner.client;
    _info = widget.runner.info;
    _attach(widget.runner);
  }

  void _attach(MatrixWidgetBrowserRuntimeRunner runner) {
    final runtime = _runtime!;
    final spec = widget.launch.toSurfaceSpec();
    if (widget.presentation == PresentationMode.standalone) {
      _standaloneSurface = StandaloneBrowserSurface.attached(
        runtime: runtime,
        spec: spec,
        surfaceId: runner.surfaceId,
      );
    } else {
      _embeddedSurface = EmbeddedBrowserSurface.attached(
        runtime: runtime,
        spec: spec,
        surfaceId: runner.surfaceId,
      );
    }
    _eventSubscription = runner.surfaceEvents.listen(_onSurfaceEvent);
    _closedSubscription?.cancel();
    _closedSubscription = runner.onClosed.listen((_) {
      if (!widget.onExitController.isClosed) {
        widget.onExitController.add(null);
      }
    });
  }

  void _onSurfaceEvent(SurfaceEvent event) {
    if (!mounted) return;
    // Disallowed links become explicit external actions; the embed stays.
    if (event is NavigationEvent &&
        event.navigation.outcome == NavigationOutcome.external) {
      final target = Uri.tryParse(event.navigation.url);
      if (target != null) LinkUtils.open(target, context: context);
      return;
    }
    if (event is FailedEvent) {
      setState(() => _error ??= StateError(event.failure.message));
    } else if (event is ClosedEvent) {
      // An unexpected close (anything but dispose) surfaces retryable UI
      // instead of stranding a dead frame.
      setState(() => _error ??= StateError('Embedded browser closed'));
    }
  }

  Future<void> _retry() async {
    setState(() {
      _error = null;
      _revision += 1;
      _lastSize = null;
    });
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _closedSubscription?.cancel();
    _closedSubscription = null;
    await _embeddedSurface?.dispose();
    _embeddedSurface = null;
    await _standaloneSurface?.dispose();
    _standaloneSurface = null;
    try {
      // The adapter serializes opens and disposes the previous session, so
      // the retry closes the failed surface before opening a fresh one with
      // no profile, host, or owned-window leak.
      final runner = await _adapter.open(
        launch: widget.launch,
        room: _room,
        client: _client,
        info: _info,
        context: context,
      );
      if (!mounted) {
        await runner.dispose();
        return;
      }
      // Registered through the component so capability prompts and the
      // one-active-session rule keep working across retries.
      widget.component.registerRunner(runner);
      setState(() => _attach(runner));
    } catch (e, s) {
      Log.onError(e, s, content: 'Failed to reopen Matrix widget surface');
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    // State.dispose cannot await: subscriptions and presentation state are
    // torn down first, then the adapter closes the runtime surface and the
    // host destroys the browser and releases the surface.
    unawaited(_eventSubscription?.cancel());
    unawaited(_closedSubscription?.cancel());
    unawaited(_embeddedSurface?.dispose());
    unawaited(_standaloneSurface?.dispose());
    unawaited(_adapter.dispose());
    _focusNode.dispose();
    super.dispose();
  }

  void _forwardResize(Size size) {
    final surface = _embeddedSurface;
    if (surface == null || !surface.isReady || _error != null) return;
    if (_lastSize == size) return;
    _lastSize = size;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    unawaited(
      surface
          .resize(size.width.round(), size.height.round(), dpr)
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    );
  }

  Future<void> _forwardPointer(Future<void> Function() send) async {
    try {
      await send();
    } catch (_) {
      // Input after close is a cancellation, not an error.
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final surface = _embeddedSurface;
    if (surface == null || _error != null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    // Ordered keyboard input for the embedded page. IME composition stays a
    // follow-up; the surface seam already carries it once a method channel
    // exists.
    unawaited(
      _forwardPointer(
        () => surface.key(
          event.logicalKey.keyLabel,
          event.logicalKey.debugName ?? '',
          pressed: event is KeyDownEvent,
        ),
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 36),
            const SizedBox(height: 12),
            const Text('Unable to load this widget'),
            const SizedBox(height: 12),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: _retry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    // Firing the exit stream removes the overlay window,
                    // which disposes this widget and closes the surface.
                    if (!widget.onExitController.isClosed) {
                      widget.onExitController.add(null);
                    }
                  },
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Close'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (widget.presentation == PresentationMode.standalone) {
      final surface = _standaloneSurface;
      if (surface == null) {
        return const Center(child: CircularProgressIndicator());
      }
      // Windowed CEF presents natively in its owned window; Flutter shows
      // only the status placeholder, never a texture or another engine view.
      return StandaloneBrowserWindow(
        key: ValueKey(_revision),
        surface: surface,
      );
    }

    final surface = _embeddedSurface;
    if (surface == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth > 0 && constraints.maxHeight > 0) {
            _forwardResize(
              Size(constraints.maxWidth, constraints.maxHeight),
            );
          }
          // Pointer, wheel, and focus stay ordered through the surface so
          // the widget keeps its click and scroll contract.
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              final current = _embeddedSurface;
              if (current == null) return;
              unawaited(_forwardPointer(() => current.setFocus(true)));
              unawaited(
                _forwardPointer(
                  () => current.pointer(
                    PointerKind.down,
                    event.localPosition.dx,
                    event.localPosition.dy,
                    buttons: event.buttons,
                  ),
                ),
              );
            },
            onPointerMove: (event) {
              final current = _embeddedSurface;
              if (current == null) return;
              unawaited(
                _forwardPointer(
                  () => current.pointer(
                    PointerKind.move,
                    event.localPosition.dx,
                    event.localPosition.dy,
                    buttons: event.buttons,
                  ),
                ),
              );
            },
            onPointerUp: (event) {
              final current = _embeddedSurface;
              if (current == null) return;
              unawaited(
                _forwardPointer(
                  () => current.pointer(
                    PointerKind.up,
                    event.localPosition.dx,
                    event.localPosition.dy,
                  ),
                ),
              );
            },
            onPointerSignal: (signal) {
              if (signal is! PointerScrollEvent) return;
              final current = _embeddedSurface;
              if (current == null) return;
              unawaited(
                _forwardPointer(
                  () => current.wheel(
                    signal.localPosition.dx,
                    signal.localPosition.dy,
                    signal.scrollDelta.dx,
                    signal.scrollDelta.dy,
                  ),
                ),
              );
            },
            child: EmbeddedBrowserView(
              key: ValueKey(_revision),
              surface: surface,
            ),
          );
        },
      ),
    );
  }
}
