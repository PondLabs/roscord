// How long the person at this machine has been away from their keyboard and
// mouse. This is not the same as the app being idle: someone sitting in a
// voice channel while they play a game or read in another window is at their
// desk, and someone who walked off with roscord focused is not.
//
// What each platform can answer with:
// - Windows: GetLastInputInfo, which covers the whole session's keyboard and
//   mouse, whatever has focus.
// - Linux: GNOME's Mutter idle monitor or KDE's screen saver over D-Bus,
//   otherwise the X11 screen saver extension. A bare Wayland compositor with
//   neither service tells us nothing.
// - Browser: the Idle Detection API when the page has already been given
//   permission for it, otherwise input in the page alone. Nothing here ever
//   raises a permission prompt.
// - Android, iOS, macOS: nothing, and the watcher falls back to how long the
//   app has been in the background.
import 'system_idle_stub.dart'
    if (dart.library.ffi) 'system_idle_native.dart'
    if (dart.library.js_interop) 'system_idle_web.dart' as platform;

/// How long since the last keyboard, mouse or touch input, or null when this
/// platform cannot tell us.
Future<Duration?> systemIdleTime() => platform.systemIdleTime();
