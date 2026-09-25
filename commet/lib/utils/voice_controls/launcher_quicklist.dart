import 'dart:async';

import 'package:commet/config/platform_utils.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/utils/voice_controls/voice_call_watcher.dart';
import 'package:commet/utils/voice_controls/voice_controls.dart';
import 'package:dbus/dbus.dart';

/// Puts the call controls in the app icon's menu in docks that read Unity's
/// LauncherEntry quicklists: Ubuntu Dock, Dash to Dock (with the Dbusmenu
/// typelib) and Plank. KDE Plasma and plain GNOME Shell ignore quicklists;
/// they get the desktop file's actions (issue #146).
///
/// The dock learns where the menu is from a `com.canonical.Unity.
/// LauncherEntry.Update` signal, and asks for it over D-Bus from then on.
class LauncherQuicklist {
  LauncherQuicklist({
    DBusClient? bus,
    VoiceCallWatcher? watcher,
    this.desktopId = "chat.commet.commetapp.desktop",
  })  : _bus = bus,
        _watcher = watcher ?? VoiceCallWatcher.instance;

  static final LauncherQuicklist instance = LauncherQuicklist();

  static bool get supported => PlatformUtils.isLinux;

  static final menuPath = DBusObjectPath("/chat/commet/commetapp/Quicklist");
  static final _entryPath =
      DBusObjectPath("/chat/commet/commetapp/LauncherEntry");

  /// The desktop file the dock shows us under.
  final String desktopId;

  DBusClient? _bus;
  final VoiceCallWatcher _watcher;
  QuicklistMenu? _menu;
  final List<StreamSubscription> _subs = [];

  Future<void> start() async {
    final bus = _bus ??= DBusClient.session();
    final menu = _menu = QuicklistMenu(_watcher, menuPath);
    await bus.registerObject(menu);
    _watcher.start();
    _subs.add(_watcher.changes.listen((_) => menu.changed()));
    // A dock that starts after us asks nobody: tell it when it appears.
    _subs.add(bus.nameOwnerChanged
        .where((e) => e.name == "com.canonical.Unity" && e.newOwner != null)
        .listen((_) => _announce()));
    await _announce();
  }

  Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    final menu = _menu;
    if (menu != null) await _bus?.unregisterObject(menu);
    _menu = null;
  }

  Future<void> _announce() async {
    try {
      await _bus?.emitSignal(
          path: _entryPath,
          interface: "com.canonical.Unity.LauncherEntry",
          name: "Update",
          values: [
            DBusString("application://$desktopId"),
            DBusDict.stringVariant({"quicklist": menuPath}),
          ]);
    } catch (e, s) {
      Log.onError(e, s, content: "Could not announce the launcher quicklist");
    }
  }
}

/// The quicklist itself: the call controls, with labels that follow the
/// call. A `com.canonical.dbusmenu` menu, version 3.
class QuicklistMenu extends DBusObject {
  QuicklistMenu(this._watcher, DBusObjectPath path) : super(path);

  static const _interface = "com.canonical.dbusmenu";

  final VoiceCallWatcher _watcher;
  int _revision = 1;

  /// Tells the dock the menu has changed, so it asks for it again.
  void changed() {
    _revision++;
    emitSignal(_interface, "LayoutUpdated", [
      DBusUint32(_revision),
      const DBusInt32(0),
    ]).catchError((Object e, StackTrace s) {
      Log.onError(e, s, content: "Could not update the launcher quicklist");
    });
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case "GetLayout":
        final parent = (call.values[0] as DBusInt32).value;
        final layout = layoutOf(_watcher.state);
        return DBusMethodSuccessResponse([
          DBusUint32(_revision),
          parent == 0 ? layout : _item(layout, parent) ?? layout,
        ]);
      case "GetGroupProperties":
        final ids = (call.values[0] as DBusArray)
            .children
            .map((id) => (id as DBusInt32).value);
        final layout = layoutOf(_watcher.state);
        return DBusMethodSuccessResponse([
          DBusArray(DBusSignature("(ia{sv})"), [
            for (final id in ids)
              if (_item(layout, id) case final item?)
                DBusStruct([item.children[0], item.children[1]]),
          ]),
        ]);
      case "GetProperty":
        final id = (call.values[0] as DBusInt32).value;
        final name = (call.values[1] as DBusString).value;
        final item = _item(layoutOf(_watcher.state), id);
        final value = item == null
            ? null
            : (item.children[1] as DBusDict).mapStringVariant()[name];
        return value == null
            ? DBusMethodErrorResponse.invalidArgs()
            : DBusMethodSuccessResponse([DBusVariant(value)]);
      case "Event":
        _event((call.values[0] as DBusInt32).value,
            (call.values[1] as DBusString).value);
        return DBusMethodSuccessResponse();
      case "EventGroup":
        for (final event in (call.values[0] as DBusArray).children) {
          final fields = (event as DBusStruct).children;
          _event(
              (fields[0] as DBusInt32).value, (fields[1] as DBusString).value);
        }
        return DBusMethodSuccessResponse([DBusArray.int32([])]);
      case "AboutToShow":
        return DBusMethodSuccessResponse([const DBusBoolean(false)]);
      case "AboutToShowGroup":
        return DBusMethodSuccessResponse(
            [DBusArray.int32([]), DBusArray.int32([])]);
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != _interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    return switch (name) {
      "Version" => DBusGetPropertyResponse(const DBusUint32(3)),
      "TextDirection" => DBusGetPropertyResponse(const DBusString("ltr")),
      "Status" => DBusGetPropertyResponse(const DBusString("normal")),
      "IconThemePath" => DBusGetPropertyResponse(DBusArray.string([])),
      _ => DBusMethodErrorResponse.unknownProperty(),
    };
  }

  void _event(int id, String event) {
    if (event != "clicked") return;
    if (id < 1 || id > VoiceControl.values.length) return;
    _watcher.press(VoiceControl.values[id - 1]);
  }

  /// The item [id] in [layout], the root's own children only.
  static DBusStruct? _item(DBusStruct layout, int id) {
    for (final child in (layout.children[2] as DBusArray).children) {
      final item = (child as DBusVariant).value as DBusStruct;
      if ((item.children[0] as DBusInt32).value == id) return item;
    }
    return null;
  }

  /// The dbusmenu layout for [state]: a root (id 0) whose children are the
  /// controls shown, with ids one past their [VoiceControl] index.
  static DBusStruct layoutOf(VoiceCallState state) => DBusStruct([
        const DBusInt32(0),
        DBusDict.stringVariant({
          "children-display": const DBusString("submenu"),
        }),
        DBusArray.variant([
          for (final button in state.controls)
            DBusStruct([
              DBusInt32(button.control.index + 1),
              DBusDict.stringVariant({
                "label": DBusString(button.label),
                "icon-name": DBusString(_icon(button)),
              }),
              DBusArray.variant([]),
            ]),
        ]),
      ]);

  /// Names from the icon theme, so the shell draws them for its own light or
  /// dark look. Adwaita and Breeze both have these.
  static String _icon(VoiceControlButton button) => switch (button.control) {
        VoiceControl.mute => button.active
            ? "microphone-sensitivity-muted-symbolic"
            : "audio-input-microphone-symbolic",
        VoiceControl.deafen => "audio-headphones-symbolic",
        VoiceControl.disconnect => "call-stop-symbolic",
      };
}
