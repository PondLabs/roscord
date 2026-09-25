import 'package:commet/config/platform_utils.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';

import 'browser_call_controls_stub.dart'
    if (dart.library.js_interop) 'web/browser_call_controls_web.dart'
    as platform;

/// The call controls outside the tab in a browser (issue #146): the Media
/// Session actions the browser offers, and a Document Picture-in-Picture
/// panel with mute, deafen and disconnect that floats over other windows
/// (Chrome, Edge 116+, Firefox 151+). Safari only gets the Media Session.
class BrowserCallControls {
  static bool get supported => PlatformUtils.isWeb;

  static Future<void> start() => platform.start();

  /// The browser can float the controls panel.
  static bool get canPopOut => platform.canPopOut;

  /// Floats the controls panel. Only works from a click.
  static void popOut() => platform.popOut();
}

/// A Media Session action the page handles during a call.
enum CallSessionAction {
  /// Mutes or unmutes: Chrome's video picture-in-picture window, Safari's
  /// capture controls.
  toggleMicrophone("togglemicrophone"),

  /// Ends the call. There is no action for deafening.
  hangUp("hangup"),

  /// Chrome 120+ fires this when the tab is left during a call, and lets the
  /// page open its picture-in-picture window without a click.
  enterPictureInPicture("enterpictureinpicture");

  const CallSessionAction(this.name);

  /// The action's name in the Media Session spec.
  final String name;
}

/// What the page tells the browser's media session for a call.
class MediaSessionPlan {
  const MediaSessionPlan({
    required this.actions,
    required this.microphoneActive,
  });

  /// The actions to handle; the rest are cleared.
  final Set<CallSessionAction> actions;

  /// The microphone as the browser should show it, or null to leave it be.
  final bool? microphoneActive;

  /// [canPopOut]: the browser has Document Picture-in-Picture, for the
  /// controls panel.
  static MediaSessionPlan of(VoiceCallState state, {required bool canPopOut}) {
    if (!state.inCall) {
      return const MediaSessionPlan(actions: {}, microphoneActive: null);
    }
    return MediaSessionPlan(
      actions: {
        CallSessionAction.toggleMicrophone,
        CallSessionAction.hangUp,
        if (canPopOut) CallSessionAction.enterPictureInPicture,
      },
      // Deafened counts as muted, as everywhere else.
      microphoneActive: !state.muted,
    );
  }
}
