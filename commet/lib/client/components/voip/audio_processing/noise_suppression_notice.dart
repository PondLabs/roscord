// Telling the user when the noise suppression they asked for is not the one
// running. It used to be a log line only: the call went on with WebRTC's
// basic suppressor and the user heard nothing about it, since nobody hears
// their own microphone in a call.
import 'package:commet/ui/organisms/dj/dj_toast.dart';
import 'package:intl/intl.dart';

String get messageNoiseSuppressionFellBack => Intl.message(
    "Noise suppression isn't getting your microphone, so the basic one is on for the rest of this call.",
    name: "messageNoiseSuppressionFellBack",
    desc:
        "Shown during a call when the app's noise suppression stopped receiving microphone audio and a simpler one took over");

/// Our DSP was given up on for the rest of the call.
void warnNoiseSuppressionFellBack() =>
    DjToast.show(messageNoiseSuppressionFellBack, isError: true);

String messageNoiseSuppressionUnavailable(String reason) => Intl.message(
    "Noise suppression can't run ($reason). The basic one is on instead.",
    args: [reason],
    name: "messageNoiseSuppressionUnavailable",
    desc:
        "Shown when a call starts with noise suppression turned on but the app's own suppressor cannot run; the reason is technical");

bool _warnedUnavailable = false;

/// The user asked for our DSP and it cannot run here. Once per run of the
/// app: it is the same news at every call.
void warnNoiseSuppressionUnavailable(String reason) {
  if (_warnedUnavailable) return;
  _warnedUnavailable = true;
  DjToast.show(messageNoiseSuppressionUnavailable(reason), isError: true);
}
