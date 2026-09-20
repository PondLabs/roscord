// Runs one piece of work per key at a time, so callers that ask for the same
// thing while it is already running await the same future. Pure Dart.
import 'dart:async';

class InFlight<T> {
  final Map<String, Future<T>> _running = {};

  /// Whether [run]'s future for [key] has not settled yet.
  bool isRunning(String key) => _running.containsKey(key);

  /// [start]'s future for [key], or the one already running. The entry is
  /// dropped when that future settles, however it settles.
  Future<T> run(String key, Future<T> Function() start) {
    final running = _running[key];
    if (running != null) return running;
    final future = start();
    _running[key] = future;
    // The callback must not return a future: `whenComplete` awaits whatever
    // it returns, and while the callback runs the map still holds this very
    // future, so `=> _running.remove(key)` would make it wait on itself
    // forever. A void body cannot.
    unawaited(future.then<void>((_) {
      _running.remove(key);
    }, onError: (Object _) {
      _running.remove(key);
    }));
    return future;
  }
}
