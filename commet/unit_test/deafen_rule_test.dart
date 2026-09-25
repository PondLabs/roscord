// Mute and deafen together, the way Discord has them (issue #146): deafening
// keeps whatever mute was chosen, and undeafening goes back to it.
import 'package:commet/client/components/voip/deafen_rule.dart';
import 'package:test/test.dart';

void main() {
  test("undeafening someone muted before deafening leaves them muted", () {
    final rule = DeafenRule();
    rule.deafen(micMuted: true);
    expect(rule.undeafen(micMuted: true), isTrue, reason: "still muted");
  });

  test("undeafening someone heard before deafening opens the mic again", () {
    final rule = DeafenRule();
    rule.deafen(micMuted: false);
    expect(rule.undeafen(micMuted: true), isFalse);
  });

  test("deafening again keeps the mute from before the first time", () {
    // The second time round the mic reads muted, because deafening muted it.
    final rule = DeafenRule();
    rule.deafen(micMuted: false);
    rule.deafen(micMuted: true);
    expect(rule.undeafen(micMuted: true), isFalse);
  });

  test("unmuting while deafened undeafens", () {
    // Even someone who had muted before deafening: they asked to talk, so
    // the session opens the mic as well.
    final rule = DeafenRule();
    rule.deafen(micMuted: true);
    rule.unmute();
    expect(rule.deafened, isFalse);
  });

  test("undeafening someone not deafened leaves their mic as it is", () {
    // CallManager.undeafen() tells every session, deafened or not.
    expect(DeafenRule().undeafen(micMuted: true), isTrue);
    expect(DeafenRule().undeafen(micMuted: false), isFalse);
  });
}
