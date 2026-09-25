import 'package:commet/client/call_manager.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:intl/intl.dart';

/// A call control shown outside the window.
enum VoiceControl { mute, deafen, disconnect }

/// A control as a surface shows it.
class VoiceControlButton {
  const VoiceControlButton(this.control,
      {required this.active, required this.label});

  final VoiceControl control;

  /// Whether it shows its slashed icon.
  final bool active;

  /// Its tooltip, or its label in a menu.
  final String label;
}

/// The call as the controls outside the window see it.
class VoiceCallState {
  const VoiceCallState(
      {required this.inCall, required this.muted, required this.deafened});

  static const idle =
      VoiceCallState(inCall: false, muted: false, deafened: false);

  final bool inCall;

  /// Not heard: every call we are in has us muted or deafened. Deafened
  /// counts as muted, as it does in Discord.
  final bool muted;

  /// Deafened in a call, as [CallManager.isDeafened] reads it.
  final bool deafened;

  @override
  bool operator ==(Object other) =>
      other is VoiceCallState &&
      other.inCall == inCall &&
      other.muted == muted &&
      other.deafened == deafened;

  @override
  int get hashCode => Object.hash(inCall, muted, deafened);

  @override
  String toString() =>
      "VoiceCallState(inCall: $inCall, muted: $muted, deafened: $deafened)";

  static VoiceCallState of(Iterable<VoipSession> sessions) {
    final calls = sessions.where(_isIn);
    return VoiceCallState(
      inCall: calls.isNotEmpty,
      muted: calls.isNotEmpty &&
          calls.every((call) => call.isMicrophoneMuted || call.isDeafened),
      deafened: calls.any((call) => call.isDeafened),
    );
  }

  /// A call is one being sat in from the moment it is joined or placed, as
  /// Discord shows its buttons while still connecting. One ringing is not.
  static bool _isIn(VoipSession session) =>
      session.state == VoipState.connected ||
      session.state == VoipState.connecting ||
      session.state == VoipState.outgoing;

  static String get labelVoiceControlMute => Intl.message("Mute",
      name: "labelVoiceControlMute",
      desc: "Call control outside the window (taskbar thumbnail, Dock menu, "
          "tray) that mutes the microphone");

  static String get labelVoiceControlUnmute => Intl.message("Unmute",
      name: "labelVoiceControlUnmute",
      desc: "Call control outside the window that unmutes the microphone, "
          "and undeafens when deafened");

  static String get labelVoiceControlDeafen => Intl.message("Deafen",
      name: "labelVoiceControlDeafen",
      desc: "Call control outside the window that stops the user hearing the "
          "call");

  static String get labelVoiceControlUndeafen => Intl.message("Undeafen",
      name: "labelVoiceControlUndeafen",
      desc: "Call control outside the window that lets the user hear the call "
          "again");

  static String get labelVoiceControlDisconnect => Intl.message("Disconnect",
      name: "labelVoiceControlDisconnect",
      desc: "Call control outside the window that leaves the call");

  List<VoiceControlButton> get controls => [
        if (inCall) ...[
          VoiceControlButton(VoiceControl.mute,
              active: muted,
              label: muted ? labelVoiceControlUnmute : labelVoiceControlMute),
          VoiceControlButton(VoiceControl.deafen,
              active: deafened,
              label: deafened
                  ? labelVoiceControlUndeafen
                  : labelVoiceControlDeafen),
          VoiceControlButton(VoiceControl.disconnect,
              active: false, label: labelVoiceControlDisconnect),
        ],
      ];

  /// Does what [control]'s label says. Going by the state shown rather than
  /// toggling what the first session happens to be keeps the two in step.
  void press(VoiceControl control, CallManager calls) {
    switch (control) {
      case VoiceControl.mute:
        muted ? calls.unmute() : calls.mute();
      case VoiceControl.deafen:
        deafened ? calls.undeafen() : calls.deafen();
      case VoiceControl.disconnect:
        calls.disconnect();
    }
  }
}
