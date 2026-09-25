import 'dart:async';

import 'package:commet/client/call_manager.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/main.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';

/// Tells every surface outside the window (tray, taskbar thumbnail, Dock
/// menu, launcher quicklist, browser panel) what the call looks like, and
/// only when that changes.
class VoiceCallWatcher {
  VoiceCallWatcher(this._calls);

  static final VoiceCallWatcher instance =
      VoiceCallWatcher(() => clientManager?.callManager);

  final CallManager? Function() _calls;

  VoiceCallState _state = VoiceCallState.idle;
  VoiceCallState get state => _state;

  final StreamController<VoiceCallState> _changes =
      StreamController.broadcast();
  Stream<VoiceCallState> get changes => _changes.stream;

  bool _started = false;
  CallManager? _watching;
  final List<StreamSubscription> _listSubs = [];
  final List<StreamSubscription> _sessionSubs = [];
  Timer? _poll;

  /// Starts watching; later calls do nothing.
  ///
  /// Mute changes are announced by LiveKit sessions but not by legacy 1:1
  /// ones, and an app refresh replaces the call manager: [poll] catches both.
  void start({Duration? poll = const Duration(seconds: 1)}) {
    if (_started) return;
    _started = true;
    if (poll != null) _poll = Timer.periodic(poll, (_) => refresh());
    refresh();
  }

  void stop() {
    _started = false;
    _poll?.cancel();
    _poll = null;
    for (final sub in [..._listSubs, ..._sessionSubs]) {
      sub.cancel();
    }
    _listSubs.clear();
    _sessionSubs.clear();
    _watching = null;
  }

  /// Presses [control] as the surfaces show it: they all draw [state].
  void press(VoiceControl control) {
    final calls = _calls();
    if (calls == null) return;
    _state.press(control, calls);
    refresh();
  }

  /// Presses the control named [name] (a [VoiceControl] name), for surfaces
  /// that hand back strings: menus, D-Bus, method channels.
  void pressNamed(String name) {
    final control = VoiceControl.values.asNameMap()[name];
    if (control != null) press(control);
  }

  /// Reads the calls again, and tells the listeners if anything changed.
  void refresh() {
    if (!_started) return;
    final calls = _calls();
    if (!identical(calls, _watching)) _watch(calls);

    final state =
        VoiceCallState.of(calls?.currentSessions ?? const <VoipSession>[]);
    if (state == _state) return;
    _state = state;
    _changes.add(state);
  }

  void _watch(CallManager? calls) {
    for (final sub in _listSubs) {
      sub.cancel();
    }
    _listSubs.clear();
    _watching = calls;
    if (calls != null) {
      _listSubs.add(calls.currentSessions.onListUpdated.listen((_) {
        _watchSessions();
        refresh();
      }));
    }
    _watchSessions();
  }

  void _watchSessions() {
    for (final sub in _sessionSubs) {
      sub.cancel();
    }
    _sessionSubs.clear();
    for (final session in _watching?.currentSessions ?? const []) {
      _sessionSubs.add(session.onStateChanged.listen((_) => refresh()));
    }
  }
}
