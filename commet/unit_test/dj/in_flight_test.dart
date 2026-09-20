// The DJ's song cache used to hang on its in-flight dedup: the callback
// passed to `whenComplete` returned the entry it had just removed, which was
// the very future being completed, so that future waited on itself forever.
// A song downloaded, its cache record was written, and the booth still showed
// "Loading…" for good. These tests pin the behaviour.
import 'dart:async';

import 'package:commet/client/components/dj/in_flight.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a caller gets the work done, not a future that waits on itself',
      () async {
    final inFlight = InFlight<int>();
    final value = await inFlight
        .run('song', () async => 7)
        .timeout(const Duration(seconds: 2));
    expect(value, 7);
    expect(inFlight.isRunning('song'), isFalse);
  });

  test('concurrent runs of one key share a single future', () async {
    final inFlight = InFlight<int>();
    final completer = Completer<int>();
    var starts = 0;
    Future<int> start() {
      starts++;
      return completer.future;
    }

    final first = inFlight.run('song', start);
    final second = inFlight.run('song', start);
    expect(identical(first, second), isTrue);
    expect(starts, 1);
    expect(inFlight.isRunning('song'), isTrue);

    completer.complete(3);
    expect(await first, 3);
    expect(await second, 3);
    expect(inFlight.isRunning('song'), isFalse);
  });

  test('different keys run independently', () async {
    final inFlight = InFlight<int>();
    expect(await inFlight.run('a', () async => 1), 1);
    expect(await inFlight.run('b', () async => 2), 2);
  });

  test('a failed run settles and forgets its key, so a retry can run',
      () async {
    final inFlight = InFlight<int>();
    await expectLater(
        inFlight.run('song', () async => throw StateError('boom')),
        throwsStateError);
    expect(inFlight.isRunning('song'), isFalse);
    expect(await inFlight.run('song', () async => 1), 1);
  });
}
