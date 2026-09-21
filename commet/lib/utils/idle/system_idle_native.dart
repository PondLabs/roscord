// Desktop idle time. See system_idle.dart for what this is for.
import 'dart:ffi';
import 'dart:io';

import 'package:commet/debug/log.dart';
import 'package:dbus/dbus.dart';
import 'package:ffi/ffi.dart';

Future<Duration?> systemIdleTime() async {
  if (Platform.isWindows) return _windowsIdleTime();
  if (Platform.isLinux) return _linuxIdleTime();
  return null;
}

// ---------------------------------------------------------------- Windows

typedef _GetLastInputInfoNative = Int32 Function(Pointer<Uint32>);
typedef _GetLastInputInfo = int Function(Pointer<Uint32>);
typedef _GetTickCount64Native = Uint64 Function();
typedef _GetTickCount64 = int Function();

_GetLastInputInfo? _getLastInputInfo;
_GetTickCount64? _getTickCount64;
bool _windowsUnavailable = false;

/// GetLastInputInfo reports the last input to this session as a 32 bit tick
/// count, so it is compared against the low half of the current one: both
/// wrap every 49.7 days, and only the difference matters.
Duration? _windowsIdleTime() {
  if (_windowsUnavailable) return null;

  try {
    _getLastInputInfo ??= DynamicLibrary.open('user32.dll')
        .lookupFunction<_GetLastInputInfoNative, _GetLastInputInfo>(
            'GetLastInputInfo');
    _getTickCount64 ??= DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_GetTickCount64Native, _GetTickCount64>(
            'GetTickCount64');
  } catch (e) {
    Log.w("Idle time is unavailable on this machine: $e");
    _windowsUnavailable = true;
    return null;
  }

  // LASTINPUTINFO: a UINT size followed by a DWORD tick count.
  final info = calloc<Uint32>(2);
  try {
    info[0] = 8;
    if (_getLastInputInfo!(info) == 0) return null;
    final now = _getTickCount64!() & 0xFFFFFFFF;
    var idle = now - info[1];
    if (idle < 0) idle += 0x100000000;
    return Duration(milliseconds: idle);
  } finally {
    calloc.free(info);
  }
}

// ------------------------------------------------------------------ Linux

/// Where a Linux desktop's idle time comes from. Whichever answers first is
/// kept, and a source that stops answering sends us looking again.
enum _LinuxIdleSource { mutter, screenSaver, x11 }

_LinuxIdleSource? _linuxSource;
DBusClient? _bus;

Future<Duration?> _linuxIdleTime() async {
  final known = _linuxSource;
  if (known != null) {
    final idle = await _readLinux(known);
    if (idle != null) return idle;
    _linuxSource = null;
  }

  for (final source in _LinuxIdleSource.values) {
    final idle = await _readLinux(source);
    if (idle != null) {
      _linuxSource = source;
      return idle;
    }
  }

  return null;
}

Future<Duration?> _readLinux(_LinuxIdleSource source) async {
  try {
    return switch (source) {
      _LinuxIdleSource.mutter => await _mutterIdleTime(),
      _LinuxIdleSource.screenSaver => await _screenSaverIdleTime(),
      _LinuxIdleSource.x11 => _x11IdleTime(),
    };
  } catch (_) {
    // Every one of these is absent on some desktop; the next is tried.
    return null;
  }
}

DBusClient _sessionBus() => _bus ??= DBusClient.session();

/// GNOME, through the compositor that sees the input.
Future<Duration?> _mutterIdleTime() async {
  final object = DBusRemoteObject(_sessionBus(),
      name: 'org.gnome.Mutter.IdleMonitor',
      path: DBusObjectPath('/org/gnome/Mutter/IdleMonitor/Core'));
  final result = await object.callMethod(
      'org.gnome.Mutter.IdleMonitor', 'GetIdletime', [],
      replySignature: DBusSignature('t'));
  return Duration(milliseconds: result.returnValues.first.asUint64());
}

/// KDE, and anything else carrying the screen saver interface. In seconds.
Future<Duration?> _screenSaverIdleTime() async {
  final object = DBusRemoteObject(_sessionBus(),
      name: 'org.freedesktop.ScreenSaver',
      path: DBusObjectPath('/org/freedesktop/ScreenSaver'));
  final result = await object.callMethod(
      'org.freedesktop.ScreenSaver', 'GetSessionIdleTime', [],
      replySignature: DBusSignature('u'));
  return Duration(seconds: result.returnValues.first.asUint32());
}

typedef _XOpenDisplayNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _XOpenDisplay = Pointer<Void> Function(Pointer<Utf8>);
typedef _XDefaultRootWindowNative = IntPtr Function(Pointer<Void>);
typedef _XDefaultRootWindow = int Function(Pointer<Void>);
typedef _XScreenSaverAllocInfoNative = Pointer<Void> Function();
typedef _XScreenSaverAllocInfo = Pointer<Void> Function();
typedef _XScreenSaverQueryInfoNative = Int32 Function(
    Pointer<Void>, IntPtr, Pointer<Void>);
typedef _XScreenSaverQueryInfo = int Function(
    Pointer<Void>, int, Pointer<Void>);

Pointer<Void>? _display;
Pointer<Void>? _saverInfo;
int _rootWindow = 0;
_XScreenSaverQueryInfo? _queryInfo;

/// The X11 screen saver extension, which is what an X session that is
/// neither GNOME nor KDE has. Under XWayland it only sees input that reached
/// an X client, so it is the last thing tried.
Duration? _x11IdleTime() {
  if (_queryInfo == null) {
    final xlib = DynamicLibrary.open('libX11.so.6');
    final xss = DynamicLibrary.open('libXss.so.1');
    final display =
        xlib.lookupFunction<_XOpenDisplayNative, _XOpenDisplay>('XOpenDisplay')(
      nullptr,
    );
    if (display == nullptr) return null;
    _display = display;
    _rootWindow =
        xlib.lookupFunction<_XDefaultRootWindowNative, _XDefaultRootWindow>(
            'XDefaultRootWindow')(display);
    _saverInfo = xss.lookupFunction<_XScreenSaverAllocInfoNative,
        _XScreenSaverAllocInfo>('XScreenSaverAllocInfo')();
    if (_saverInfo == nullptr) return null;
    _queryInfo = xss.lookupFunction<_XScreenSaverQueryInfoNative,
        _XScreenSaverQueryInfo>('XScreenSaverQueryInfo');
  }

  if (_queryInfo!(_display!, _rootWindow, _saverInfo!) == 0) return null;
  // XScreenSaverInfo: Window, int state, int kind, then two unsigned longs,
  // the second of which is the idle time in milliseconds.
  final idle = _saverInfo!.cast<Uint64>()[3];
  return Duration(milliseconds: idle);
}
