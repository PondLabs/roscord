import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:commet/browser_runtime.dart';
import 'package:commet/client/components/widgets/widget_component.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_adapter.dart';
import 'package:commet/client/matrix/components/widgets/matrix_widget_transport.dart';
import 'package:test/test.dart';

void main() {
  test('builds Matrix substitutions, metadata, origin policy, and profile', () {
    final launch = _launch(
      widgetUrl: 'https://widgets.test/view?user=\$matrix_user_id'
          '&room=\$matrix_room_id&theme=\$org.matrix.msc2873.client_theme'
          '&device=\$org.matrix.msc3819.matrix_device_id'
          '&base=\$org.matrix.msc4039.matrix_base_url'
          '&colors=\$chat.commet.color_scheme',
      capabilities: {'org.matrix.msc2762.timeline': true},
    );

    final url = launch.initialUrl;
    expect(url.scheme, 'https');
    expect(url.host, 'widgets.test');
    expect(url.queryParameters['user'], '@alice:example.test');
    expect(url.queryParameters['room'], '!room:example.test');
    expect(url.queryParameters['theme'], 'dark');
    expect(url.queryParameters['device'], 'DEVICE');
    expect(url.queryParameters['base'], 'https://matrix.example.test/');
    expect(url.queryParameters['parentUrl'], matrixWidgetAppOrigin);
    expect(url.queryParameters['widgetId'], 'widget-1');
    expect(url.queryParameters['accountId'], 'account-record-1');
    expect(url.queryParameters['profileKey'], 'account-record-1');
    expect(url.queryParameters['colors'], contains('surface'));

    final spec = launch.toSurfaceSpec();
    expect(spec.profileKey, ProfileKey('account-record-1'));
    expect(spec.presentation, PresentationMode.embedded);
    expect(spec.privacy, PrivacyMode.persistent);
    expect(spec.policy.allowedOrigins, contains('https://widgets.test'));
    expect(spec.policy.allowedOrigins, contains(matrixWidgetAppOrigin));
    expect(launch.capabilities['org.matrix.msc2762.timeline'], isTrue);
    expect(spec.policy.capabilities, isEmpty);
  });

  test('installs the adapter-owned JavaScript bridge as a generic command',
      () async {
    final runtime = _RecordingRuntime();
    final adapter = MatrixWidgetAdapter(runtime: runtime);

    await adapter.openSession(_launch());

    final install = runtime.commands.single as ScriptCommand;
    final value = Map<String, dynamic>.from(install.envelope.value as Map);
    expect(value['operation'], matrixWidgetBridgeInstallOperation);
    expect(value['protocol_version'], matrixWidgetBridgeProtocolVersion);
    expect(value['script'], contains('window.__roscordBrowserRuntimeReceive'));
    expect(value['script'], contains(matrixWidgetFromWidgetStoragePrefix));
    expect(value['script'], contains(matrixWidgetToWidgetStoragePrefix));
    expect(value['script'], contains('sessionStorage.removeItem'));
    expect(value['script'], contains('window.ipc.postMessage'));

    await adapter.dispose();
  });

  test('keeps session-storage keys, newline framing, and command ordering',
      () async {
    final runtime = _RecordingRuntime();
    final session = MatrixWidgetBrowserRuntimeSession(
      runtime: runtime,
      surfaceId: const SurfaceId(1),
      profileKey: ProfileKey('account-record-1'),
      pageOrigin: 'https://widgets.test',
    );

    final messages = <Uint8List>[];
    final subscription = session.transceiver.onReceived.listen(messages.add);
    session.transceiver.send(Uint8List.fromList(utf8.encode('{"one":1}')));
    session.transceiver.send(Uint8List.fromList(utf8.encode('{"two":2}')));
    await _flush();

    expect(runtime.commands, hasLength(2));
    final first = runtime.commands[0] as ScriptCommand;
    final second = runtime.commands[1] as ScriptCommand;
    expect(first.sequence, 1);
    expect(second.sequence, 2);
    expect(
      (first.envelope.value as Map)['storage_key'],
      '$matrixWidgetToWidgetStoragePrefix' '1',
    );
    expect((first.envelope.value as Map)['payload'], '_{"one":1}\n');

    runtime.emit(
      ScriptMessageEvent(
        const SurfaceId(1),
        2,
        ScriptEnvelope(
          source: ScriptSource.page,
          origin: 'https://widgets.test',
          channel: matrixWidgetScriptChannel,
          requestId: 'from-page-1',
          value: {
            'storage_key': '$matrixWidgetFromWidgetStoragePrefix' '1',
            'payload': '_{"nested":true}\n',
          },
        ),
      ),
    );
    await _flush();
    expect(messages.map(utf8.decode), ['{"nested":true}']);

    runtime.emit(
      ScriptMessageEvent(
        const SurfaceId(1),
        3,
        ScriptEnvelope(
          source: ScriptSource.page,
          origin: 'https://attacker.test',
          channel: matrixWidgetScriptChannel,
          requestId: 'bad-origin',
          value: {
            'storage_key': '$matrixWidgetFromWidgetStoragePrefix' '2',
            'payload': '_{"ignored":true}\n',
          },
        ),
      ),
    );
    await _flush();
    expect(messages.map(utf8.decode), ['{"nested":true}']);

    await subscription.cancel();
    await session.dispose();
  });

  test('decodes recursive ArrayBuffer and Blob widget values', () async {
    final transceiver = _BufferTransceiver();
    final transport = MatrixWidgetTransport(transceiver);
    final received = <Map<String, dynamic>>[];
    final subscription = transport.onReceived.listen(received.add);

    transceiver.emit({
      'api': 'fromWidget',
      'widgetId': 'widget-1',
      'requestId': 'request-1',
      'action': 'binary',
      'data': {
        'list': [
          {
            '__type': 'ArrayBuffer',
            'data': 'AQID',
          },
          {
            'deep': {
              '__type': 'Blob',
              'data': 'BAU=',
            },
          },
        ],
      },
    });
    await _flush();

    final data = received.single['data'] as Map<String, dynamic>;
    expect(data['list'][0], isA<Uint8List>());
    expect(data['list'][0], orderedEquals([1, 2, 3]));
    final blob = (data['list'][1] as Map<String, dynamic>)['deep'];
    expect(blob, isA<MatrixWidgetBlob>());
    expect((blob as MatrixWidgetBlob).bytes, orderedEquals([4, 5]));

    await transport.send({
      'api': 'fromWidget',
      'widgetId': 'widget-1',
      'requestId': 'request-2',
      'action': 'binary',
      'data': {
        'list': [
          Uint8List.fromList([6, 7]),
          MatrixWidgetBlob(Uint8List.fromList([8, 9])),
        ],
      },
    });
    final encoded = jsonDecode(utf8.decode(transceiver.sent.single))
        as Map<String, dynamic>;
    final encodedList =
        (encoded['data'] as Map<String, dynamic>)['list'] as List<dynamic>;
    expect(encodedList[0], {'__type': 'ArrayBuffer', 'data': 'Bgc='});
    expect(encodedList[1], {'__type': 'Blob', 'data': 'CAk='});

    await subscription.cancel();
  });

  test('opening a session disposes the previous session before replacing it',
      () async {
    final runtime = _RecordingRuntime();
    final adapter = MatrixWidgetAdapter(runtime: runtime);
    final first = await adapter.openSession(_launch());
    final second = await adapter.openSession(_launch(widgetId: 'widget-2'));

    expect(runtime.closedSurfaceIds, [first.surfaceId]);
    expect(adapter.activeSession, same(second));

    await second.dispose();
    expect(adapter.activeSession, isNull);
  });

  test('concurrent opens are serialized and leave one active session',
      () async {
    final runtime = _RecordingRuntime();
    final adapter = MatrixWidgetAdapter(runtime: runtime);

    final sessions = await Future.wait([
      adapter.openSession(_launch(widgetId: 'widget-1')),
      adapter.openSession(_launch(widgetId: 'widget-2')),
    ]);

    expect(runtime.closedSurfaceIds, [sessions.first.surfaceId]);
    expect(adapter.activeSession, same(sessions.last));
    expect(runtime.openedSpecs, hasLength(2));

    await adapter.dispose();
  });

  test('bridge installation failure closes the surface and can be retried',
      () async {
    final runtime = _RecordingRuntime()..failNextCommand = true;
    final adapter = MatrixWidgetAdapter(runtime: runtime);

    await expectLater(adapter.openSession(_launch()), throwsA(isA<Object>()));
    expect(runtime.closedSurfaceIds, [const SurfaceId(1)]);

    final session = await adapter.openSession(_launch(widgetId: 'retry'));
    expect(session.surfaceId, const SurfaceId(2));
    await adapter.dispose();
  });

  test('surface failure before ready unblocks initialization', () async {
    final runtime = _RecordingRuntime();
    final session = MatrixWidgetBrowserRuntimeSession(
      runtime: runtime,
      surfaceId: const SurfaceId(1),
      profileKey: ProfileKey('account-record-1'),
      pageOrigin: 'https://widgets.test',
    );

    final initializing = session.initialize();
    runtime.emit(
      const FailedEvent(
        SurfaceId(1),
        1,
        SurfaceFailure(FailureKind.runtimeLost, 'host stopped'),
      ),
    );

    await expectLater(initializing, throwsA(isA<StateError>()));
    await session.dispose();
  });
}

MatrixWidgetAdapterLaunch _launch({
  String widgetUrl = 'https://widgets.test/view',
  String widgetId = 'widget-1',
  Map<String, bool> capabilities = const {},
}) {
  return MatrixWidgetAdapterLaunch(
    widgetUrl: widgetUrl,
    widgetId: widgetId,
    accountId: 'account-record-1',
    profileKey: 'account-record-1',
    matrixUserId: '@alice:example.test',
    matrixRoomId: '!room:example.test',
    matrixDisplayName: 'Alice',
    matrixDeviceId: 'DEVICE',
    matrixBaseUrl: 'https://matrix.example.test/',
    colorSchemeJson: '{"surface":"#fff"}',
    theme: 'dark',
    presentation: PresentationMode.embedded,
    privacy: PrivacyMode.persistent,
    capabilities: capabilities,
  );
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

class _RecordingRuntime implements BrowserRuntime {
  final StreamController<SurfaceEvent> _events =
      StreamController<SurfaceEvent>.broadcast();
  final List<SurfaceCommand> commands = [];
  final List<SurfaceId> closedSurfaceIds = [];
  final List<SurfaceSpec> openedSpecs = [];
  bool failNextCommand = false;
  int _nextSurfaceId = 1;

  @override
  Stream<SurfaceEvent> events() => _events.stream;

  @override
  Future<SurfaceId> open(SurfaceSpec spec) async {
    openedSpecs.add(spec);
    final id = SurfaceId(_nextSurfaceId++);
    Future<void>.delayed(
      Duration.zero,
      () => _events.add(ReadyEvent(id, 1, spec.initialNavigation)),
    );
    return id;
  }

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) async {
    if (failNextCommand) {
      failNextCommand = false;
      throw StateError('simulated bridge installation failure');
    }
    commands.add(command);
  }

  @override
  Future<void> close(SurfaceId surfaceId) async {
    closedSurfaceIds.add(surfaceId);
    _events.add(ClosedEvent(surfaceId, 1, CloseReason.user));
  }

  void emit(SurfaceEvent event) => _events.add(event);
}

class _BufferTransceiver implements WidgetTransceiver {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  final List<Uint8List> sent = [];

  @override
  Stream<Uint8List> get onReceived => _events.stream;

  @override
  void send(Uint8List data) => sent.add(data);

  void emit(Map<String, dynamic> value) {
    _events.add(Uint8List.fromList(utf8.encode(jsonEncode(value))));
  }
}
