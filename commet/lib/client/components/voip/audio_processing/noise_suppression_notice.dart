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
