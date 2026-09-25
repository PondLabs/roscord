# Issue 146: voice controls outside the window

Research note for https://github.com/PondLabs/roscord/issues/146:
Discord-style call controls (mute, deafen, disconnect) under the taskbar
thumbnail on Windows, and the nearest native equivalent on macOS, Linux
and the browser. Written 2026-09-25 against
`main` at `ecfbfeb5`. Every claim links the source it was checked against;
"unconfirmed" marks what no primary source settles.

## 1. What Discord does

Read from Discord's own code, not from blogs:

- The desktop core, `discord_desktop_core` from the Linux client 1.0.158
  (`~/.config/discord/app-1.0.158/modules/discord_desktop_core-1`, module
  9090 of `core.asar`'s `bundle.js`).
- The web client that decides what to show: stable build 621195
  (`VERSION_HASH ab3e028a`), fetched from https://discord.com/app on
  2026-09-25. The class `ThumbarButtonsManager` is in
  `/assets/web.e223a2399a103bfa.js`, en-US strings are in
  `/assets/fba8349e43ad1ff7.js`, and pt-BR strings are in
  `/assets/57e7d0a76814cb1a.js`.

### Per platform

| Platform | Mechanism | Source |
|---|---|---|
| Windows | `BrowserWindow.setThumbarButtons` (Electron's thumbnail toolbar) | desktop core module 9090 |
| macOS | The same buttons as a Touch Bar (`setTouchBar`). No Dock menu: the bundle never calls `app.dock.setMenu` | desktop core module 9090 |
| Linux | Nothing. The module logs `Unknown operating system`. The tray menu has Mute / Deafen checkboxes | desktop core modules 9090, 1275 |

### When the buttons show

- Whenever `SelectedChannelStore.getVoiceChannelId()` is set. That covers guild
  voice, stage and DM/group calls, and it starts as soon as a channel is
  selected, before the RTC connection is up.
- Otherwise the client sends `[]`, and the toolbar hides.

### What the buttons are

The buttons come in this order: `VIDEO` (when the engine supports video), then `MUTE`, `DEAFEN` and
`DISCONNECT`.

| Button | `active` (icon shows the slashed variant) | Tooltip en-US / pt-BR | Click |
|---|---|---|---|
| MUTE | `isSelfMute()`, which is also true while deafened, without mic permission, or with PTT forced | not muted: Mute / Silenciar; muted: Unmute / Dessilenciar | `toggleSelfMute` |
| DEAFEN | `isSelfDeaf()` | Deafen / Desativar áudio; Undeafen / Reativar áudio | `toggleSelfDeaf` |
| DISCONNECT | always | Disconnect / Desconectar | `disconnect()` |

Other details of the web client:

- The only flag it uses is `disabled`, and only on VIDEO when there is no camera.
  Server mute and server deafen are not reflected in the toolbar.
- It debounces 100 ms and sends only when the array deep-differs from the
  last one.
- Theme: the web client passes `isSystemDarkMode` from its native
  `discord_utils` module, and the desktop core picks
  `${name}${active ? "" : "-off"}${dark ? "" : "-light"}.png`. The icons are 48×48.
  They are grey glyphs (light grey for dark taskbars, dark grey for light ones),
  and the muted and deafened variants add a red slash. The dark-mode flag is read
  only when the buttons are sent, so a theme switch does not repaint them until
  the next mute change.

### Mute and deafen together

From the `MediaEngineStore` reducers, module 25578:

- Deafening sets only `deaf`. The stored `mute` flag is kept, and you
  *appear* muted because `isSelfMute()` includes deaf.
- Undeafening with the deafen button flips `deaf` back, so **the mute state
  from before deafening returns**. If you were muted, you stay muted.
- Pressing mute ("Unmute") while deafened sets `mute = false` and
  `deaf = false`, so you end up unmuted and undeafened.

roscord differs on the second point. Both `MatrixLivekitVoipSession.setDeafened(false)`
and `MatrixVoipSession.setDeafened(false)` always re-enable the microphone. The
sequence mute, deafen, undeafen therefore leaves the mic open.

## 2. Windows: thumbnail toolbar

### The API: [`ITaskbarList3`](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nn-shobjidl_core-itaskbarlist3)

- [`ThumbBarAddButtons`](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-itaskbarlist3-thumbbaraddbuttons)
  - "The maximum number of buttons allowed is 7."
  - "Buttons cannot be added or deleted later … they can be shown and hidden
    through ThumbBarUpdateButtons … The toolbar itself cannot be removed
    without re-creating the window."
  - When space runs short, buttons are cut from the right.
- A click arrives as `WM_COMMAND` on that hwnd, with `HIWORD(wParam) = THBN_CLICKED`
  and `LOWORD` = the button id.
- [`THUMBBUTTON`](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/ns-shobjidl_core-thumbbutton)
  - Fields: `dwMask`, `iId`, `iBitmap`, `hIcon`, `szTip[260]`, `dwFlags`.
  - The taskbar copies the `hIcon`.
  - [Flags](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/ne-shobjidl_core-thumbbuttonflags):
    `ENABLED`, `DISABLED`, `DISMISSONCLICK`, `NOBACKGROUND`, `HIDDEN`,
    `NONINTERACTIVE`.
- Timing: `TaskbarButtonCreated` "must be received by your application
  before it calls any ITaskbarList3 method", and `HrInit` comes first
  ([HrInit](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-itaskbarlist-hrinit)).
- An elevated process needs `ChangeWindowMessageFilterEx(..., MSGFLT_ALLOW)`
  for `TaskbarButtonCreated` and `WM_COMMAND`. Microsoft's own
  [sample](https://github.com/microsoft/Windows-classic-samples/blob/main/Samples/Win7Samples/winui/shell/appshellintegration/TaskbarThumbnailToolbar/ThumbnailToolbar.cpp)
  does this.
- Hiding the window removes the taskbar button
  ([Old New Thing](https://devblogs.microsoft.com/oldnewthing/20031229-00/?p=41283)).
  The next show creates a new button and sends a new `TaskbarButtonCreated`,
  so the toolbar has to be added again. After an Explorer restart,
  `TaskbarCreated` is broadcast
  ([Taskbar](https://learn.microsoft.com/en-us/windows/win32/shell/taskbar)).
- Icons: "32-bit and of dimensions `GetSystemMetrics(SM_CXICON)`", and
  high-DPI assets are expected
  ([ThumbBarSetImageList](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-itaskbarlist3-thumbbarsetimagelist)).
  The same page adds: images are used "with light and dark color modes and
  contrast themes … Choose assets that remain visually clear in all these
  contexts". It suggests either updating the icons on theme change or using
  glyphs with a white fill and black outline. Under per-monitor DPI, use
  `GetSystemMetricsForDpi`
  ([GetSystemMetrics](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getsystemmetrics)).
  The runner manifest declares PerMonitorV2.
- Electron's implementation
  ([`taskbar_host.cc`](https://github.com/electron/electron/blob/8453f6268a0aa8fdbe7054464ae0a54252c3868a/shell/browser/ui/win/taskbar_host.cc))
  claims all 7 slots up front, hiding the unused ones. After that it only
  calls `ThumbBarUpdateButtons`.

### Theme

- `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize` holds two values
  ([settings](https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-common)):
  - `SystemUsesLightTheme`, "light/dark color mode for Windows";
  - `AppsUseLightTheme`, "for an app".
- The taskbar follows Windows mode, not app mode
  ([Microsoft support](https://support.microsoft.com/en-us/accessibility/windows/use-color-and-contrast-for-accessibility-in-microsoft-365),
  [MRT](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/mrtcore/tailor-resources-lang-scale-contrast)).
  The runner's title bar reads `AppsUseLightTheme` (`win32_window.cpp`), and
  Flutter's `platformBrightness` follows app mode too. Neither can be used for
  taskbar icons.
- **Unconfirmed:** whether the thumbnail flyout itself is drawn in Windows
  mode. No Microsoft page says so. Discord keys its icon set on "system dark
  mode", which is consistent with it.
- Change notification: `WM_SETTINGCHANGE` with `lParam == "ImmersiveColorSet"`.
  This is undocumented in
  [WM_SETTINGCHANGE](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-settingchange),
  but it is what Microsoft's own
  [Windows Terminal](https://github.com/microsoft/terminal/blob/main/src/cascadia/WindowsTerminal/WindowEmperor.cpp)
  listens for. It also fires on lock and on UAC prompts, so compare the value
  before acting.
- High contrast: check `SPI_GETHIGHCONTRAST` and `HCF_HIGHCONTRASTON`
  ([HIGHCONTRASTW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-highcontrastw)),
  at startup and on `WM_SYSCOLORCHANGE`
  ([high contrast parameter](https://learn.microsoft.com/en-us/windows/win32/winauto/high-contrast-parameter)).
  The guidance is: "Images that would typically be drawn in multiple colors
  should be drawn using the foreground and background colors selected for
  text". `COLOR_BTNTEXT` is the colour for interactive UI
  ([contrast themes](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/high-contrast-themes)).

### In this repo

- `FlutterWindow::MessageHandler` sees every top-level message after plugins
  have had theirs.
- `tray_manager` forwards every `WM_COMMAND` to Dart as a menu click
  (`third_party/tray_manager/windows/tray_manager_plugin.cpp`). Its menu ids
  come from `menu_base`, which keeps them in 1024–65535. A thumbnail click
  carries `0x1800xxxx`, so it finds no menu item and nothing happens.
- COM is initialised STA in `main.cpp`.

## 3. macOS: Dock menu

- [`applicationDockMenu(_:)`](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationdockmenu(_:))
  returns an `NSMenu`, and "the target and action for each menu item are
  passed to the dock". Building it on demand is supported: an Apple DTS
  engineer
  [on the developer forums](https://developer.apple.com/forums/thread/762250)
  said "build/update the menu on demand … any significant delay will be
  noticeable". Chromium and Electron rebuild the menu on every call.
- The [HIG for Dock menus](https://developer.apple.com/design/human-interface-guidelines/dock-menus)
  asks for "actions that are most likely to be useful when your app isn't
  frontmost". For toggles, the [HIG menus page](https://developer.apple.com/design/human-interface-guidelines/menus)
  suggests a changeable label (Show Map / Hide Map). It also says to use icons
  "sparingly" and for all items or none.
- **Unconfirmed:** whether `NSMenuItem.image` and `.state` render in a Dock menu.
  Electron documents that badges are
  "[Not displayed in Dock menus](https://github.com/electron/electron/blob/main/docs/api/menu-item.md)",
  and Chromium sets images only outside the Dock. Text labels are the safe
  choice. The Dock draws the menu in the system appearance, so text needs no
  theming.
- Whether a Dock menu click activates the app is **unconfirmed**. Chromium calls
  `activateIgnoringOtherApps` explicitly when it wants that, which implies it
  does not happen on its own.
- The Touch Bar (Discord's choice) only shows the frontmost app's items
  ([NSTouchBar](https://developer.apple.com/documentation/appkit/nstouchbar)),
  which defeats the purpose. Apple also dropped it from the MacBook Pro in
  November 2023
  ([M3 specs](https://support.apple.com/en-us/117735)).
- The Dock badge is reserved for notification counts
  ([HIG](https://developer.apple.com/design/human-interface-guidelines/notifications)).
- Flutter: `FlutterAppDelegate` does not implement `applicationDockMenu`, and
  `FlutterAppLifecycleDelegate` has no hook for it. Our `AppDelegate.swift`
  can override it, just as it already overrides other optional delegate
  methods. Use a `FlutterMethodChannel` on the engine's messenger.

## 4. Linux: `.desktop` actions, LauncherEntry quicklists, tray

No Linux shell has Windows-style thumbnail buttons.

### `.desktop` actions

- The [Desktop Entry spec](https://specifications.freedesktop.org/desktop-entry/latest/extra-actions.html)
  defines them as static entries with `Name`, `Icon` and `Exec`.
- With `DBusActivatable=true` a launcher sends `org.freedesktop.Application.ActivateAction`
  instead of running `Exec`
  ([D-Bus section](https://specifications.freedesktop.org/desktop-entry/latest/dbus.html)).

| Launcher | Shows actions | How it launches |
|---|---|---|
| GNOME Shell dash and app grid | yes ([appMenu.js](https://gitlab.gnome.org/GNOME/gnome-shell/-/raw/main/js/ui/appMenu.js)) | GLib |
| KDE Plasma task manager | yes, in an "Actions" section ([ContextMenu.qml](https://invent.kde.org/plasma/plasma-desktop/-/raw/master/applets/taskmanager/qml/ContextMenu.qml)) | KIO |
| Dash to Dock / Ubuntu Dock | yes ([appIcons.js](https://raw.githubusercontent.com/micheleg/dash-to-dock/master/appIcons.js)) | GLib |
| Cinnamon grouped window list | yes | GLib |
| XFCE launcher and docklike | yes | runs `Exec` |
| XFCE tasklist | no | — |
| Plank | yes | always runs `Exec` |
| elementary Dock | yes | GLib |

Because Plank and XFCE ignore `DBusActivatable`, `Exec` has to work on its own.

### What the repo already has

- `commet --shortcut <name>` (`commet/linux/main.cc`, `shortcuts.h`) sends
  `chat.commet.commetapp.Shortcuts.<name>` to the running app over D-Bus and
  exits before GTK starts. `system_wide_shortcuts_linux.dart` owns the name
  and maps it to `SystemWideShortcuts.shortcuts`.
- The forwarder never calls `dbus_connection_flush` before exiting.
  libdbus only queues on `dbus_connection_send`, so delivery of the message
  still needs checking.
- The Flatpak desktop file has `Actions=ToggleMute;Mute;Unmute`. The Debian
  one has no actions.

### LauncherEntry quicklists

- The quicklist is `com.canonical.Unity.LauncherEntry.Update(app_uri, a{sv})`
  with `quicklist` = the object path of a dbusmenu
  ([Unity LauncherAPI, archived](https://web.archive.org/web/20231220063114/https://wiki.ubuntu.com/Unity/LauncherAPI)).
- It is dynamic, with labels and checkmarks. Only these read it:
  - Dash to Dock and Ubuntu Dock, when the Dbusmenu typelib is present
    ([launcherAPI.js](https://raw.githubusercontent.com/micheleg/dash-to-dock/master/launcherAPI.js)).
    Ubuntu recommends that typelib.
  - Plank, when built with dbusmenu.
- **Not** Plasma, which reads count, progress and urgent only
  ([smartlauncherbackend.cpp](https://invent.kde.org/plasma/plasma-desktop/-/raw/master/applets/taskmanager/smartlauncherbackend.cpp)),
  and not vanilla GNOME Shell, Cinnamon, XFCE or elementary.

### Plasma's task tooltip

The tooltip shows the window thumbnail plus MPRIS Previous / Play-Pause / Next
([PlayerController.qml](https://invent.kde.org/plasma/plasma-desktop/-/raw/master/applets/taskmanager/qml/PlayerController.qml)).
It has no custom buttons. Borrowing MPRIS for mic mute would also hijack
media keys, so it is ruled out.

### Tray

The SNI tray (tray_manager, appindicator) already has Mute and Deafen.

- The Flatpak build has no tray:
  - its runtime ships no appindicator (see `third_party/README.md`);
  - its manifest lacks `--talk-name=org.kde.StatusNotifierWatcher`, which
    Flatpak requires "to register an item"
    ([desktop integration](https://github.com/flatpak/flatpak-docs/blob/master/docs/desktop-integration.rst)).

### Flatpak

- `Exec` is rewritten to `flatpak run --command=…` in every group, actions
  included ([flatpak-dir.c](https://raw.githubusercontent.com/flatpak/flatpak/main/common/flatpak-dir.c)).
- The app may own and talk to its own id
  ([sandbox permissions](https://github.com/flatpak/flatpak-docs/blob/master/docs/sandbox-permissions.rst)),
  so `--shortcut` works inside the sandbox.
- Emitting the LauncherEntry signal needs no permission. Watching for
  `com.canonical.Unity` does: `--talk-name=com.canonical.Unity`
  ([electron.rst](https://github.com/flatpak/flatpak-docs/blob/master/docs/electron.rst)).

### Icons and theme

- The Icon Naming Spec has no `-symbolic` convention
  ([spec](https://specifications.freedesktop.org/icon-naming/latest/)). It is a
  GTK convention for icons recoloured to the foreground colour
  ([load_symbolic](https://docs.gtk.org/gtk3/method.IconInfo.load_symbolic.html)).
- Both Adwaita and Breeze ship `audio-input-microphone-symbolic`,
  `microphone-sensitivity-muted-symbolic`, `audio-headphones-symbolic` and
  `call-stop-symbolic`.
- An icon *name* in an action or quicklist item is drawn by the shell from
  the current icon theme, so it follows light, dark and live theme switches
  with no work on our side.

### Window matching

- `g_set_prgname("chat.commet.commetapp")` gives both the Wayland app_id and
  the X11 `WM_CLASS`, matching `StartupWMClass`
  ([gdkwindow-wayland.c](https://gitlab.gnome.org/GNOME/gtk/-/raw/gtk-3-24/gdk/wayland/gdkwindow-wayland.c)).
- Actions and LauncherEntry key on the desktop file id, not on the display
  server.

## 5. Browser

### Media Session

- The [spec](https://w3c.github.io/mediasession/) defines:
  - the actions `togglemicrophone` ("mute or unmute the user's microphone"),
    `togglecamera`, `hangup` and `enterpictureinpicture`;
  - `setMicrophoneActive`.
- No action mutes output, so there is nothing for deafen.
- Chrome and Edge draw these buttons **only in a video Picture-in-Picture
  window**. Global media controls and Document PiP do not show them
  ([video_picture_in_picture_window_controller_impl.cc](https://chromium.googlesource.com/chromium/src/+/main/content/browser/picture_in_picture/video_picture_in_picture_window_controller_impl.cc),
  [media_item_ui_updated_view.cc](https://chromium.googlesource.com/chromium/src/+/main/components/global_media_controls/public/views/media_item_ui_updated_view.cc)).
  A video PiP needs a video track, so a voice-only call would have none.
- Firefox has none of these actions
  ([MediaSession.webidl](https://searchfox.org/firefox-main/source/dom/webidl/MediaSession.webidl),
  [bug 1874041](https://bugzilla.mozilla.org/show_bug.cgi?id=1874041)), and
  `setActionHandler('togglemicrophone')` throws there.
- Safari 18.4 supports `togglemicrophone` and `setMicrophoneActive`, but not
  `hangup`
  ([BCD](https://raw.githubusercontent.com/mdn/browser-compat-data/main/api/MediaSession.json),
  [WebKit 18.4](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/)).

### Document Picture-in-Picture

- An always-on-top window whose content the page draws itself
  ([spec](https://wicg.github.io/document-picture-in-picture/),
  [Chrome docs](https://developer.chrome.com/docs/web-platform/document-picture-in-picture)).
- `requestWindow()` needs a user gesture.
- Support: Chrome and Edge 116, [Firefox 151](https://developer.mozilla.org/en-US/docs/Mozilla/Firefox/Releases/151),
  not Safari ([standards position](https://github.com/WebKit/standards-positions/issues/41)).
- From Chrome 120 it can open by itself when the user switches tabs. This needs
  an `enterpictureinpicture` handler and active mic capture, and the window
  closes when the tab is visible again
  ([automatic PiP](https://developer.chrome.com/blog/automatic-picture-in-picture)).
  Switching to another app does not trigger it (the occlusion trigger is off
  by default,
  [media_switches.cc](https://chromium.googlesource.com/chromium/src/+/main/media/base/media_switches.cc)).
- Flutter cannot render into it yet
  ([flutter#181953](https://github.com/flutter/flutter/issues/181953)), so it
  needs plain DOM.
- Theme: the PiP document has its own `prefers-color-scheme` and
  `forced-colors` media queries, which follow the browser and OS live.

### Manifest shortcuts

They are static launch links ([manifest](https://w3c.github.io/manifest/)),
not live controls.

## 6. Summary

| Platform | Mechanism | Mute | Deafen | Disconnect | State visible | Theme | Limits |
|---|---|---|---|---|---|---|---|
| Windows 10/11 | Thumbnail toolbar | yes | yes | yes | icon and tooltip | we draw it: `SystemUsesLightTheme` + high contrast, live | max 7 buttons, fixed set; re-add after hide/show |
| macOS | Dock menu | yes | yes | yes | changeable label | drawn by the system | right click; only reflects state when opened |
| Linux, all shells | `.desktop` actions | toggle | toggle | yes | no (static) | themed icon names | label cannot change |
| Linux, Ubuntu Dock / Dash to Dock / Plank | LauncherEntry quicklist | yes | yes | yes | label and checkmark | themed icon names | not Plasma or vanilla GNOME |
| Linux, with an SNI host | tray menu | yes | yes | yes | label and tray icon | existing colour badges | no tray in the Flatpak |
| Chrome/Edge 116+, Firefox 151+ | Document PiP panel | yes | yes | yes | icon and label | `prefers-color-scheme` and `forced-colors`, live | opens on a click; Chrome also on tab switch |
| Safari 18.4+ | Media Session | yes (system UI) | no | no | `setMicrophoneActive` | drawn by the browser | no floating window |
