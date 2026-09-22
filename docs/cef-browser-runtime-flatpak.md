# Flatpak Matrix presentations

Flatpak embedded and standalone Matrix surfaces run from the bundled CEF
payload under `/app` on both required compositor cells (Flatpak X11 and
Flatpak Wayland on GNOME Platform 48, x86_64).

Both presentations share one release-authoritative engine: CEF
windowless/off-screen rendering with CPU `OnPaint` copied into client-owned
memory. Embedded presents as a Flutter texture
(`osr-cpu-flutter-texture`); standalone presents the same OSR/CPU frames
inside a roscord-owned top-level window (`osr-cpu-owned-window`).

## Both presentations load without host CEF, host WebKitGTK, or GPU

Both cells report the same bundled paths:

- Flatpak X11 embedded and standalone use OSR/CPU frames from `/app`;
- Flatpak Wayland embedded and standalone use OSR/CPU frames from `/app`,
  with no native Wayland child embedding.

The session type parser accepts only `x11` and `wayland`. Unknown values
fail closed instead of selecting another cell or a fallback engine. The Dart
`FlatpakEmbeddedPresenter`/`FlatpakStandalonePresenter` and the Rust
`browser_flatpak` module expose the same parsing, path, and flag vocabulary
so fixtures stay aligned.

`resolveFlatpakCefBundlePath` accepts only `/app/`-rooted paths and rejects
traversal, control characters, and empty values. `isHostCefPath` and
`isHostWebKitGtkPath` deny `/usr/lib`, `/opt`, `/run/host`, `/host`, and any
host engine name. `resolveFlatpakBackend` accepts only `cef-osr-cpu` (alias
`cef`); GPU-only names fail so CPU rendering stays release-authoritative.
Static contract checks assert the presenter sources contain the OSR/CPU,
`/app`, texture/owned-window vocabulary and none of the host engine names.

## User-namespace/seccomp sandboxing and least-privilege permissions

`cef_host` and all CEF children run as the ordinary non-elevated Flatpak
user with user-namespace and seccomp sandboxing inside GNOME Platform 48.
SUID is not assumed.

`validateFlatpakFinishArgs` pins least privilege: `ipc`, `fallback-x11`,
`wayland`, `pulseaudio`, `network`, and `dri` must be present while
`--device=all`, host/home filesystem access, host OS bindings, and
`flatpak-spawn` escapes fail closed with `policyViolation`. The manifest no
longer grants `device=all`: Flatpak camera and capture go through portals,
GPU import stays an optional optimization behind CPU `OnPaint`, and denial never broadens the sandbox. Static contract checks read the real
`chat.commet.commetapp.yaml` and assert the same allow/deny sets.

## File, camera, microphone, and screen capture use portals

File selection uses the FileChooser portal with read-only staged copies.
Camera and microphone are deny-by-default and mediated by roscord plus the
Camera portal; grants stay scoped to account, requesting origin, top-level
origin, and capability. Screen capture uses the XDG ScreenCast/PipeWire
portal with fresh consent per request; no persistent display grant exists.

`flatpakUsesPortalForCapability` covers `camera`, `microphone`,
`camera+microphone`, `display_video`, `display_audio`,
`display_video+display_audio`, `file`, `download`, and `upload`.
`assertFlatpakPortalDenialKeepsSandbox` proves denial, dismissal, timeout,
disconnect, and unsupported outcomes never broaden the sandbox: no manifest
change, no device/filesystem/D-Bus addition follows a denial. The Rust
`browser_media` portal-outcome table (`CapturePortalOutcome`,
`HostPermissionRegistry::report_portal_outcome`) already emits sanitized
`capture_denied` failures without origins, paths, tokens, or page content.

## CPU rendering remains fully functional

CPU/OSR is the release-authoritative path. Both presenters only construct
with `FlatpakRendering.cpuOsr`; accelerated imports (dma-buf or otherwise)
remain gated experiments and are never required. Frames carry size, stride,
format, and sequence and are never CEF pointers or borrowed buffers; the
frame budget mirrors the wire limit and over-budget frames fail closed.
Frame-ready events coalesce to the newest client-owned reference while every
other control event is preserved in order. Standalone geometry, z-order,
focus, input, IME, resize/DPI, popup ownership, and close delegate to ordered
`BrowserRuntime` commands so X11 and Wayland stay aligned, and host loss
drops the frame and reports reconnecting instead of crashing the app.

## No native child embedding, dynamic broadening, or host filesystem access

Native child embedding and unowned browser windows are never introduced.
Both the Dart and Rust presenters deny fallback engines, host engines, child
embedding, and unowned windows by name (case-insensitive, substring-based)
and fail closed on unknown backend names. Static contract checks assert no
`GDK_BACKEND`, `gtk_window`, `GtkWidget`, `webview`, or
`desktop_webview_window` tokens in the Flatpak sources.

`isFlatpakHostFilesystemPath`/`assertNoFlatpakHostFilesystemAccess` deny
`/host`, `/run/host`, `/home`, `/root`, and host CEF/WebKit library paths;
uploads use a portal chooser plus staging while downloads use the declared
safe destination with atomic commit. `isFlatpakDynamicBroadening`/
`assertNoFlatpakDynamicBroadening` deny `flatpak-spawn`, `flatpak override`,
and any post-denial device/filesystem/D-Bus addition. Popups inherit the
opener's account and privacy context as roscord-owned child surfaces and
close with the opener.
