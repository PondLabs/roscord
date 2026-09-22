import 'package:commet/client/components/user_presence/user_idle_watcher.dart';
import 'package:commet/client/components/user_presence/user_presence_component.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Duration? idle;
  late List<UserPresenceStatus> published;
  late DateTime now;
  late UserIdleWatcher watcher;

  setUp(() {
    idle = Duration.zero;
    published = [];
    now = DateTime(2026, 1, 1, 12);
    watcher = UserIdleWatcher(
      idleTime: () async => idle,
      publish: (status) async => published.add(status),
      now: () => now,
    );
  });

  test('someone at their machine is not away', () async {
    idle = const Duration(minutes: 14, seconds: 59);
    await watcher.poll();

    expect(watcher.isAway.value, isFalse);
    expect(published, [UserPresenceStatus.online]);
  });

  test('a quarter of an hour without input is away', () async {
    await watcher.poll();
    idle = const Duration(minutes: 15);
    await watcher.poll();

    expect(watcher.isAway.value, isTrue);
    expect(
        published, [UserPresenceStatus.online, UserPresenceStatus.unavailable]);
  });

  test('touching anything brings them back', () async {
    idle = const Duration(hours: 2);
    await watcher.poll();
    idle = Duration.zero;
    await watcher.poll();

    expect(watcher.isAway.value, isFalse);
    expect(
        published, [UserPresenceStatus.unavailable, UserPresenceStatus.online]);
  });

  test('a status that has not changed is not published again', () async {
    idle = const Duration(minutes: 20);
    await watcher.poll();
    idle = const Duration(minutes: 40);
    await watcher.poll();
    await watcher.poll();

    expect(published, [UserPresenceStatus.unavailable]);
  });

  test('listeners hear the change once', () async {
    var changes = 0;
    watcher.isAway.addListener(() => changes++);

    idle = const Duration(minutes: 30);
    await watcher.poll();
    idle = const Duration(minutes: 31);
    await watcher.poll();

    expect(changes, 1);
    expect(watcher.isAway.value, isTrue);
  });

  group('where the platform cannot tell us', () {
    setUp(() => idle = null);

    test('the app being in the foreground is not away', () async {
      await watcher.poll();

      expect(watcher.isAway.value, isFalse);
      expect(published, [UserPresenceStatus.online]);
    });

    test('a quarter of an hour in the background is away', () async {
      watcher.hiddenSince = now.subtract(const Duration(minutes: 14));
      await watcher.poll();
      expect(watcher.isAway.value, isFalse);

      now = now.add(const Duration(minutes: 2));
      await watcher.poll();
      expect(watcher.isAway.value, isTrue);
    });
  });
}
