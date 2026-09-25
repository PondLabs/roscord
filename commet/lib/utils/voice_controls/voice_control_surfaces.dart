import 'package:commet/debug/log.dart';
import 'package:commet/utils/voice_controls/browser_call_controls.dart';
import 'package:commet/utils/voice_controls/dock_menu.dart';
import 'package:commet/utils/voice_controls/launcher_quicklist.dart';
import 'package:commet/utils/voice_controls/taskbar_thumbnail.dart';

/// Starts the call controls outside the window for this platform (issue
/// #146). The tray, which has them in its menu, starts with the window
/// (WindowManagement.init).
class VoiceControlSurfaces {
  static void init() {
    if (TaskbarThumbnail.supported) {
      TaskbarThumbnail.instance.start().catchError((Object e, StackTrace s) {
        Log.onError(e, s, content: "Could not set up the taskbar buttons");
      });
    }

    if (DockMenu.supported) {
      DockMenu.instance.start().catchError((Object e, StackTrace s) {
        Log.onError(e, s, content: "Could not set up the Dock menu");
      });
    }

    if (BrowserCallControls.supported) {
      BrowserCallControls.start().catchError((Object e, StackTrace s) {
        Log.onError(e, s,
            content: "Could not set up the browser call controls");
      });
    }

    // Linux also has the desktop file's actions (linux/flatpak and
    // linux/debian), which need nothing started here.
    if (LauncherQuicklist.supported) {
      LauncherQuicklist.instance.start().catchError((Object e, StackTrace s) {
        Log.onError(e, s, content: "Could not set up the launcher quicklist");
      });
    }
  }
}
