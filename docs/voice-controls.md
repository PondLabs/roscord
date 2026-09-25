# Call controls outside the window

In a call, someone working in another window can mute, deafen or leave the
call without bringing roscord to the front. On Windows the controls are the
buttons under the taskbar thumbnail, as Discord has them; elsewhere they are
the nearest thing each platform has (issue #146). The research behind this,
with sources, is `docs/research/issue-146-voice-taskbar-controls.md`.

## What the controls do

The behaviour follows Discord's, read from its client code:

- They show while in a call, from the moment it is joined (still connecting
  included), and go when it ends. A call that is only ringing is not one.
- Mute shows the slashed mic while muted *or deafened*. Its label is "Mute"
  or "Unmute".
- Deafen shows the slashed headset while deafened. Its label is "Deafen" or
  "Undeafen".
- Disconnect leaves every call the user is in, but does not decline one that
  is ringing (`CallManager.disconnect`).
- Deafening keeps the mute underneath, and undeafening goes back to it:
  someone who muted and then deafened is still muted afterwards. Unmuting
  while deafened undeafens too. `DeafenRule` holds this, and both kinds of
  session use it, so the call panel, the shortcuts and the tray behave the
  same way.

## Where the state comes from

`lib/utils/voice_controls/`:

| File | What it does |
| --- | --- |
| `voice_controls.dart` | `VoiceCallState`: the sessions reduced to in call / muted / deafened, the controls to show, and `press` |
| `voice_call_watcher.dart` | The one watcher every surface listens to. It tells them when the state changes, and presses what they report |
| `voice_control_surfaces.dart` | Starts the surfaces for this platform |

The tray (`lib/utils/voice_tray.dart`) uses the same watcher, and its menu
has the same three controls.

## Per platform

| Platform | Surface | Where |
| --- | --- | --- |
| Windows 10/11 | Buttons under the taskbar thumbnail | `taskbar_thumbnail.dart`, `commet/windows/runner/voice_thumb_bar.cpp` |
| macOS | The Dock menu | `dock_menu.dart`, `commet/macos/Runner/AppDelegate.swift` |
| Linux, every launcher | The desktop file's actions: ToggleMute, ToggleDeafen, Disconnect | `commet/linux/flatpak/*.desktop`, `commet/linux/debian/.../*.desktop` |
| Linux, Ubuntu Dock / Dash to Dock / Plank | A LauncherEntry quicklist with labels that follow the call | `launcher_quicklist.dart` |
| Linux, any SNI tray | The tray menu | `voice_tray.dart` |
| Chrome, Edge 116+, Firefox 151+ | A floating controls panel (Document Picture-in-Picture), from the call panel's pop-out button; Chrome 120+ also opens it when the tab is left mid-call | `browser_call_controls.dart`, `web/` |
| Browsers with the Media Session call actions (Safari 18.4+, Chrome) | `togglemicrophone`, `hangup`, `setMicrophoneActive` | `web/browser_call_controls_web.dart` |

### Windows

- The runner adds the three buttons whenever the window gets a taskbar
  button: the first show, a show after hiding, and Explorer restarting. After
  that it only updates them. Windows cannot remove buttons, so outside a call
  they are hidden.
- A click arrives as `WM_COMMAND` / `THBN_CLICKED`. The runner handles it
  before the plugins, because `tray_manager` passes every `WM_COMMAND` on as a
  menu click.
- Dart draws the icons: the call panel's Material glyphs, at the size the
  taskbar asks for (`SM_CXICON` at the window's DPI). The colours:
  - The taskbar follows "Windows mode" (`SystemUsesLightTheme`), not the app
    mode or roscord's own theme, so the icons do too. They use WinUI's
    `TextFillColorPrimary`, and `SystemFillColorCritical` while muted or
    deafened.
  - A contrast theme gets `COLOR_BTNTEXT` for every glyph, and no red. The
    slash alone tells the state.
  - Theme, contrast or DPI changing (`WM_SETTINGCHANGE`, `WM_SYSCOLORCHANGE`,
    `WM_THEMECHANGED`, `WM_DPICHANGED`) redraws them straight away.

### macOS

- The Dock asks for its menu each time it opens it (`applicationDockMenu`).
  The runner builds it from the last items Dart sent: nothing outside a call.
- The items are text whose label changes (Mute / Unmute), as Apple's
  guidelines suggest for toggles. Dock menus do not reliably draw icons or
  checkmarks, and the system draws the text in its own light or dark look.
- Choosing an item does not bring the window forward.

### Linux

- No Linux shell has buttons on window thumbnails.
- The desktop file's actions run `commet --shortcut <name>`. `linux/shortcuts.h`
  sends that to the running app over D-Bus
  (`chat.commet.commetapp.Shortcuts`) and exits before GTK starts. Actions are
  static, so their labels cannot follow the call. They carry symbolic icon
  names, which the shell draws in its own theme.
- The quicklist is a `com.canonical.dbusmenu` menu announced with
  `com.canonical.Unity.LauncherEntry.Update`. KDE Plasma and plain GNOME Shell
  ignore quicklists and show the actions instead. The Flatpak needs
  `--talk-name=com.canonical.Unity` to see a dock come up after roscord;
  sending the signal needs no permission.

### Browser

- The Media Session has no action for deafening. Chrome only draws its call
  buttons in a *video* picture-in-picture window, which a voice call does not
  have. That is why the panel exists.
- The panel is plain DOM, because Flutter cannot draw into a second document
  yet. It follows the browser's light or dark look and `forced-colors` live,
  through CSS.

## Checking by hand

- Linux quicklist: `dbus-monitor --session "interface='com.canonical.Unity.LauncherEntry'"`
  shows the announcement. Then
  `gdbus call --session --dest <sender> --object-path /chat/commet/commetapp/Quicklist --method com.canonical.dbusmenu.GetLayout -- 0 -1 '@as []'`
  shows the menu.
- Linux actions: `commet --shortcut toggle_mute` (or `toggle_deafen`,
  `disconnect`) against a running instance.
