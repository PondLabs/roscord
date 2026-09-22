// Browser idle time. See system_idle.dart for what this is for.
//
// The Idle Detection API is the only way a page can tell that someone has
// left their machine rather than just left the tab, and it is behind a
// permission. Asking for it out of nowhere would be a prompt nobody expects,
// so it is used only where it has already been granted, and otherwise we
// watch input in the page: someone with roscord open in a background tab
// while they work elsewhere then reads as away, which is what other web
// chat clients do.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:commet/debug/log.dart';
import 'package:web/web.dart' as web;

@JS('IdleDetector')
extension type _IdleDetector._(JSObject _) implements web.EventTarget {
  external factory _IdleDetector();
  external JSPromise<JSAny?> start(JSObject options);
  external String get userState;
}

/// The threshold the detector is started with, and the least idle time it can
/// report. Its minimum is a minute.
const _detectorThreshold = Duration(minutes: 1);

DateTime _lastActivity = DateTime.now();
bool _listening = false;

_IdleDetector? _detector;
bool _detectorPending = false;

/// When the detector last said "idle", which it does [_detectorThreshold]
/// after the input that preceded it.
DateTime? _idleSince;

Future<Duration?> systemIdleTime() async {
  _listen();

  final detector = _detector;
  if (detector != null) {
    final since = _idleSince;
    if (since == null) return Duration.zero;
    return DateTime.now().difference(since) + _detectorThreshold;
  }

  return DateTime.now().difference(_lastActivity);
}

void _listen() {
  if (_listening) return;
  _listening = true;

  // A block body, not an arrow: `toJS` only takes a callback that returns
  // void, and an arrow would return the assignment's value.
  void onActivity(web.Event _) {
    _lastActivity = DateTime.now();
  }

  final listener = onActivity.toJS;
  for (final event in const [
    'pointermove',
    'pointerdown',
    'keydown',
    'wheel',
    'touchstart',
    'focus',
  ]) {
    web.window.addEventListener(event, listener);
  }
  web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (!web.document.hidden) _lastActivity = DateTime.now();
      }).toJS);

  _startDetector();
}

/// Starts the Idle Detection API if the page already has permission for it.
/// Querying permission does not prompt.
void _startDetector() async {
  if (_detectorPending) return;
  _detectorPending = true;

  try {
    if (!globalContext.has('IdleDetector')) return;

    final status = await web.window.navigator.permissions
        .query({'name': 'idle-detection'}.jsify() as JSObject)
        .toDart;
    if (status.state != 'granted') return;

    final detector = _IdleDetector();
    detector.addEventListener(
        'change',
        ((web.Event _) {
          _idleSince = detector.userState == 'idle'
              ? _idleSince ?? DateTime.now()
              : null;
        }).toJS);
    await detector
        .start({'threshold': _detectorThreshold.inMilliseconds}.jsify()
            as JSObject)
        .toDart;
    _idleSince = detector.userState == 'idle' ? DateTime.now() : null;
    _detector = detector;
  } catch (e) {
    Log.w("Browser idle detection is unavailable, "
        "falling back to activity in the page: $e");
  } finally {
    _detectorPending = false;
  }
}
