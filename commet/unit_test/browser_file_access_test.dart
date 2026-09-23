import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('download filename mediation', () {
    test('accepts a safe leaf name', () {
      expect(sanitizeSuggestedDownloadName('report.pdf'), 'report.pdf');
      // Windows trailing dots/spaces are stripped, not passed through.
      expect(sanitizeSuggestedDownloadName('trailing. '), 'trailing');
    });

    test('rejects traversal, separators, and drive prefixes', () {
      for (final name in [
        '../secret',
        'a/b',
        r'a\b',
        'C:secret',
        '',
        '..',
        '.',
      ]) {
        expect(
          () => sanitizeSuggestedDownloadName(name),
          throwsA(isA<BrowserRuntimeException>()),
          reason: name,
        );
      }
    });

    test('rejects control characters and reserved device names', () {
      expect(
        () => sanitizeSuggestedDownloadName('a\u0001b'),
        throwsA(isA<BrowserRuntimeException>()),
      );
      for (final name in ['CON', 'con.txt', 'NUL', 'COM1', 'lpt9.dat']) {
        expect(
          () => sanitizeSuggestedDownloadName(name),
          throwsA(isA<BrowserRuntimeException>()),
          reason: name,
        );
      }
    });

    test('never silently overwrites an existing sibling', () {
      expect(
        resolveNonOverwritingLeaf('a.pdf', {'a.pdf'}),
        'a (1).pdf',
      );
      expect(
        resolveNonOverwritingLeaf('a.pdf', {'a.pdf', 'a (1).pdf'}),
        'a (2).pdf',
      );
      expect(
        resolveNonOverwritingLeaf('README', {'readme'}),
        'README (1)',
      );
      expect(resolveNonOverwritingLeaf('a.pdf', {}), 'a.pdf');
    });

    test('download decisions round-trip through the wire protocol', () {
      const accepted = AcceptDownload('report (1).pdf');
      final decoded = SurfaceCommand.fromJson(
        Map<String, dynamic>.from(
          UploadCommand(
            sequence: 1,
            requestId: 'up-1',
            decision: const AcceptUpload(),
          ).toJson(),
        ),
      );
      expect(decoded, isA<UploadCommand>());
      expect(
        (decoded as UploadCommand).decision,
        isA<AcceptUpload>(),
      );
      expect(accepted.toJson()['kind'], 'accept');
    });
  });

  group('clipboard mediation', () {
    test('reads require a gesture and a one-shot prompt', () {
      expect(
        decideClipboardRead(userGesture: false, promptAccepted: true),
        ClipboardDecision.deny,
      );
      expect(
        decideClipboardRead(userGesture: true, promptAccepted: false),
        ClipboardDecision.deny,
      );
      expect(
        decideClipboardRead(userGesture: true, promptAccepted: true),
        ClipboardDecision.allow,
      );
    });

    test('writes require a gesture and an admitted origin', () {
      const admitted = ['https://widgets.test'];
      expect(
        decideClipboardWrite(
          userGesture: false,
          origin: 'https://widgets.test',
          admittedOrigins: admitted,
        ),
        ClipboardDecision.deny,
      );
      expect(
        decideClipboardWrite(
          userGesture: true,
          origin: 'https://attacker.test',
          admittedOrigins: admitted,
        ),
        ClipboardDecision.deny,
      );
      expect(
        decideClipboardWrite(
          userGesture: true,
          origin: 'https://widgets.test',
          admittedOrigins: admitted,
        ),
        ClipboardDecision.allow,
      );
    });

    test('upload decisions never carry a filesystem path', () {
      const accept = AcceptUpload();
      expect(accept.toJson(), {'kind': 'accept'});
      final event = UploadRequestEvent(
        const SurfaceId(3),
        2,
        requestId: 'upload-1',
        multiple: true,
        accept: const ['image/png'],
      );
      final decoded = SurfaceEvent.fromJson(
        Map<String, dynamic>.from(event.toJson()),
      );
      expect(decoded, isA<UploadRequestEvent>());
      expect((decoded as UploadRequestEvent).multiple, isTrue);
      expect((decoded).accept, ['image/png']);
    });

    test('uploads require an explicit OS chooser', () {
      expect(
        decideUpload(chooserShown: false, userConfirmed: true),
        isA<DenyUpload>(),
      );
      expect(
        decideUpload(chooserShown: true, userConfirmed: false),
        isA<CancelUpload>(),
      );
      expect(
        decideUpload(chooserShown: true, userConfirmed: true),
        isA<AcceptUpload>(),
      );
    });
  });

  group('pending request cancellation', () {
    PendingFileAccessRequest request(
      String id, [
      SurfaceId surface = const SurfaceId(1),
    ]) =>
        PendingFileAccessRequest(
          surfaceId: surface,
          requestId: id,
          kind: FileAccessKind.download,
          createdMs: 1000,
        );

    test('navigation and close cancel only that surface', () {
      final registry = PendingFileAccessRegistry()
        ..register(request('a'))
        ..register(request('b', const SurfaceId(2)));
      final cancelled = registry.cancelForNavigation(const SurfaceId(1));
      expect(cancelled.map((r) => r.requestId), ['a']);
      expect(registry.contains('a'), isFalse);
      expect(registry.contains('b'), isTrue);
      expect(registry.cancelForClose(const SurfaceId(2)), hasLength(1));
      expect(registry.length, 0);
    });

    test('host loss cancels everything; denial cancels one', () {
      final registry = PendingFileAccessRegistry()
        ..register(request('a'))
        ..register(request('b', const SurfaceId(2)));
      expect(registry.cancelDenied('a'), hasLength(1));
      expect(registry.cancelForHostLoss(), hasLength(1));
      expect(registry.length, 0);
    });

    test('timeouts and unavailable UI cancel safely', () {
      final registry = PendingFileAccessRegistry()..register(request('a'));
      expect(registry.expire(1000 + fileAccessRequestTimeoutMs), hasLength(1));
      registry.register(request('b'));
      expect(registry.cancelForUnavailableUi(const SurfaceId(1)), hasLength(1));
      expect(registry.resolve('missing'), isFalse);
    });

    test('duplicate registration is rejected', () {
      final registry = PendingFileAccessRegistry()..register(request('a'));
      expect(() => registry.register(request('a')),
          throwsA(isA<BrowserRuntimeException>()));
    });
  });
}
