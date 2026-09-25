// In the browser, the call controls reach outside the tab through the Media
// Session API (the microphone toggle and hang up, where the browser draws
// them) and a Document Picture-in-Picture panel of our own (issue #146).
import 'package:commet/utils/voice_controls/browser_call_controls.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:test/test.dart';

const _heard = VoiceCallState(inCall: true, muted: false, deafened: false);

void main() {
  group("What the media session is told", () {
    test("nothing outside a call", () {
      final plan = MediaSessionPlan.of(VoiceCallState.idle, canPopOut: true);
      expect(plan.actions, isEmpty);
      expect(plan.microphoneActive, isNull);
    });

    test("toggle the mic and hang up while in a call, mic live", () {
      final plan = MediaSessionPlan.of(_heard, canPopOut: false);
      expect(plan.actions, {
        CallSessionAction.toggleMicrophone,
        CallSessionAction.hangUp,
      });
      expect(plan.microphoneActive, isTrue);
    });

    test("the mic reads inactive while muted or deafened", () {
      for (final state in const [
        VoiceCallState(inCall: true, muted: true, deafened: false),
        VoiceCallState(inCall: true, muted: true, deafened: true),
      ]) {
        expect(MediaSessionPlan.of(state, canPopOut: false).microphoneActive,
            isFalse);
      }
    });

    test("asks to pop the panel out on a tab switch where it can", () {
      // Chrome 120+ opens it by itself when the tab is left mid-call.
      expect(MediaSessionPlan.of(_heard, canPopOut: true).actions,
          contains(CallSessionAction.enterPictureInPicture));
      expect(MediaSessionPlan.of(_heard, canPopOut: false).actions,
          isNot(contains(CallSessionAction.enterPictureInPicture)));
    });
  });
}
