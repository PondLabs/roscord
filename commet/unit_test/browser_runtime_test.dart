import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

SurfaceSpec _spec({PrivacyMode privacy = PrivacyMode.persistent}) {
  return SurfaceSpec(
    profileKey: ProfileKey('account-a'),
    presentation: PresentationMode.embedded,
    privacy: privacy,
    initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
  );
}

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  test('fake host completes lifecycle and coalesces only frames', () async {
    final runtime = FakeBrowserRuntime();
    final events = <SurfaceEvent>[];
    final subscription = runtime.events().listen(events.add);
    final surface = await runtime.open(_spec());
    await _flushEvents();

    expect(events, hasLength(1));
    expect(events.single, isA<ReadyEvent>());
    events.clear();

    runtime.publishFrame(
      surface,
      FrameReference(
        slot: 0,
        width: 10,
        height: 10,
        stride: 40,
        format: PixelFormat.bgraPremultiplied,
        sequence: 1,
      ),
    );
    final focus = runtime.command(
      surface,
      FocusCommand(sequence: 1, focused: true),
    );
    runtime.publishFrame(
      surface,
      FrameReference(
        slot: 0,
        width: 10,
        height: 10,
        stride: 40,
        format: PixelFormat.bgraPremultiplied,
        sequence: 2,
      ),
    );
    await focus;
    await _flushEvents();

    expect(events, hasLength(2));
    expect(events.first, isA<WindowChangedEvent>());
    expect((events.last as FrameReadyEvent).frame.sequence, 2);

    events.clear();
    await runtime.close(surface);
    await _flushEvents();
    expect(events.single, isA<ClosedEvent>());
    await expectLater(
      runtime.close(surface),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.staleSurface,
        ),
      ),
    );
    await subscription.cancel();
  });

  test('enforces profile and command sequence ownership', () async {
    final runtime = FakeBrowserRuntime();
    final surface = await runtime.open(_spec());
    runtime.events();

    await expectLater(
      runtime.command(
        surface,
        FocusCommand(
          sequence: 1,
          profileKey: ProfileKey('account-b'),
          focused: true,
        ),
      ),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.profileMismatch,
        ),
      ),
    );

    await runtime.command(surface, FocusCommand(sequence: 1, focused: true));
    await expectLater(
      runtime.command(surface, FocusCommand(sequence: 1, focused: false)),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.sequenceViolation,
        ),
      ),
    );
  });

  test(
    'round-trips recursive binary script values and immutable policy data',
    () {
      final envelope = ScriptEnvelope(
        source: ScriptSource.page,
        origin: 'https://widget.test',
        channel: 'widget',
        requestId: 'request-1',
        value: {
          'nested': [
            Uint8List.fromList([1, 2, 3]),
            {
              'deep': BrowserRuntimeBlob(Uint8List.fromList([4, 5])),
            },
          ],
        },
      );
      final decoded = ScriptEnvelope.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(jsonEncode(envelope.toJson())) as Map,
        ),
      );
      final nested = decoded.value as Map;
      final values = nested['nested']! as List<dynamic>;
      expect(values[0], orderedEquals([1, 2, 3]));
      expect(values[1], isA<Map>());
      final blob = (values[1] as Map)['deep'] as BrowserRuntimeBlob;
      expect(blob.bytes, orderedEquals([4, 5]));

      final privateSpec = _spec(privacy: PrivacyMode.privateContext);
      expect(privateSpec.toJson()['privacy'], 'private');
      expect(
        SurfaceSpec.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(privateSpec.toJson())) as Map,
          ),
        ).privacy,
        PrivacyMode.privateContext,
      );
    },
  );

  test('rejects malformed, oversized, and unknown framed messages', () {
    final codec = FramedCodec('nonce', maxFrameBytes: 256);
    final encoded = codec.encode(const AckWireMessage(1));
    expect(codec.decode(encoded), isA<AckWireMessage>());
    expect(codec.decodeNext(encoded.sublist(0, encoded.length - 1)), isNull);

    final malformedBody = utf8.encode('{"version":1,"nonce":"nonce"');
    final malformed = _frame(malformedBody);
    expect(() => codec.decode(malformed), throwsA(isA<ProtocolException>()));

    final unknownBody = utf8.encode(
      jsonEncode({
        'version': browserRuntimeProtocolVersion,
        'nonce': 'nonce',
        'message': {'type': 'future', 'payload': {}},
      }),
    );
    expect(
      () => codec.decode(_frame(unknownBody)),
      throwsA(
        isA<ProtocolException>().having(
          (error) => error.code,
          'code',
          'unknown_message_type',
        ),
      ),
    );

    final oversized = Uint8List(4 + 257);
    ByteData.sublistView(oversized).setUint32(0, 257, Endian.big);
    expect(
      () => codec.decode(oversized),
      throwsA(
        isA<ProtocolException>().having(
          (error) => error.code,
          'code',
          'frame_too_large',
        ),
      ),
    );
  });

  test('round-trips transport heartbeat messages', () {
    final codec = FramedCodec('nonce');
    final heartbeat = codec.encode(const HeartbeatWireMessage(7));
    expect(
      codec.decode(heartbeat),
      isA<HeartbeatWireMessage>()
          .having((message) => message.requestId, 'id', 7),
    );
    final acknowledgement = codec.encode(const HeartbeatAckWireMessage(7));
    expect(
      codec.decode(acknowledgement),
      isA<HeartbeatAckWireMessage>()
          .having((message) => message.requestId, 'id', 7),
    );
  });
}

Uint8List _frame(List<int> body) {
  final frame = Uint8List(body.length + 4);
  ByteData.sublistView(frame).setUint32(0, body.length, Endian.big);
  frame.setRange(4, frame.length, body);
  return frame;
}
