import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('diagnostic redaction', () {
    test('profile keys are hashed, never logged raw', () {
      final first = hashProfileKey('account-record-1');
      final second = hashProfileKey('account-record-1');
      final other = hashProfileKey('account-record-2');
      expect(first, second);
      expect(first, isNot(contains('account-record-1')));
      expect(first, startsWith('profile-'));
      expect(first, isNot(other));
    });

    // What the native int version produced (a signed 64-bit FNV-1a), so the
    // web-compatible one keeps identifiers already in logs.
    test('profile hashes stay what they were', () {
      expect(hashProfileKey(''), 'profile--340d631b7bdddcdb');
      expect(hashProfileKey('account-record-1'), 'profile-4055526e7907c9d4');
      expect(hashProfileKey('@alice:example.org'), 'profile-0862de498e9b8025');
      expect(hashProfileKey('a'), 'profile--509c23b379fe1374');
      expect(hashProfileKey('profile'), 'profile--7522cb619e745ef2');
    });

    test('origins are recorded instead of full URLs', () {
      expect(
        diagnosticOrigin('https://widgets.test/view?x=1#frag'),
        'https://widgets.test',
      );
      expect(
        diagnosticOrigin('https://WWW.EXAMPLE.COM/a/b'),
        'https://www.example.com',
      );
      expect(diagnosticOrigin('not a url'), '<redacted-url>');
      expect(diagnosticOrigin('file:///etc/passwd'), '<redacted-url>');
    });

    test('messages redact URLs, paths, and secrets', () {
      final redacted = redactDiagnosticMessage(
        'load https://widgets.test/page token=abc failed at C:\\private\\profile',
      );
      expect(redacted, isNot(contains('https://')));
      expect(redacted, isNot(contains('abc')));
      expect(redacted, isNot(contains('private')));
      expect(redacted, isNot(isEmpty));
    });

    test('log records hash profiles and record origins', () {
      final record = DiagnosticLogRecord(
        runtimeEpoch: 3,
        hostPid: 1234,
        surfaceId: const SurfaceId(7),
        presentation: 'embedded',
        platformCompositor: 'windows-x64',
        cefLock: 'cef-152.0.8',
        failureScope: 'host',
        failureClass: 'host_crash',
        profileKey: 'account-record-1',
        url: 'https://widgets.test/view?secret=1',
        message: 'host exited token=hunter2',
      );
      final json = record.toJson();
      expect(json['profile_hash'], hashProfileKey('account-record-1'));
      expect(json['origin'], 'https://widgets.test');
      expect(json['message'], isNot(contains('hunter2')));
      expect(json['message'], isNot(contains('https://')));
      expect(json.keys, contains('utc_time'));
      expect(json['runtime_epoch'], 3);
    });
  });

  group('consent gating', () {
    test('upload requires granted consent', () {
      final store = RateLimitedDiagnosticStore();
      expect(
        store.tryUpload(0, DiagnosticConsent.denied),
        isFalse,
      );
      expect(
        store.tryUpload(0, DiagnosticConsent.granted),
        isTrue,
      );
    });

    test('denied consent retains a local ID with copy action', () {
      final store = RateLimitedDiagnosticStore();
      final id = store.nextId(4);
      expect(store.tryUpload(0, DiagnosticConsent.denied), isFalse);
      expect(store.copyDiagnosticId(id), id.toString());
      expect(id.toString(), startsWith('d-4-'));
    });
  });

  group('rate limiting and disk budgets', () {
    test('capture is rate-limited per minute', () {
      final store = RateLimitedDiagnosticStore(maxCapturesPerMinute: 2);
      expect(store.tryCapture(0, 1), isNotNull);
      expect(store.tryCapture(1000, 1), isNotNull);
      expect(store.tryCapture(2000, 1), isNull);
      expect(store.droppedCaptures, 1);
      // A minute later the budget resets.
      expect(store.tryCapture(61000, 1), isNotNull);
    });

    test('upload is rate-limited per hour', () {
      final store = RateLimitedDiagnosticStore(maxUploadsPerHour: 1);
      expect(store.tryUpload(0, DiagnosticConsent.granted), isTrue);
      expect(store.tryUpload(1000, DiagnosticConsent.granted), isFalse);
      expect(store.droppedUploads, 1);
    });

    test('100 MiB crash spool budget is enforced', () {
      final store = RateLimitedDiagnosticStore();
      expect(store.wouldExceedDiskBudget(90 * 1024 * 1024, 20 * 1024 * 1024),
          isTrue);
      expect(store.wouldExceedDiskBudget(10 * 1024 * 1024, 1024), isFalse);
    });

    test('metric names stay low-cardinality', () {
      for (final name in [
        'runtime_starts',
        'host_exits',
        'restart_attempts',
        'surface_restores',
        'renderer_terminations',
        'gpu_events',
        'utility_events',
        'command_outcomes',
        'shutdown_results',
        'downtime_ms',
        'runtime_state',
        'active_surfaces',
      ]) {
        expect(diagnosticMetricNames, contains(name));
      }
    });
  });
}
