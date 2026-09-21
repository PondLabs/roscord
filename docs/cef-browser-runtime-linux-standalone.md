# Native Linux standalone Matrix surfaces

Matrix widgets open in roscord-owned X11 and Wayland windows using the common
OSR/CPU presenter. Both compositor cells share one release-authoritative
path: CEF windowless/off-screen rendering with CPU `OnPaint` copied into
client-owned memory and presented inside a roscord-owned top-level window.

## Compositor cells

Both cells report the same presentation path, `osr-cpu-owned-window`:

- native X11 uses OSR/CPU frames in a roscord-owned window;
- native Wayland uses OSR/CPU frames in a roscord-owned window, with no
  native Wayland child embedding.

Both cells use forced cpu rendering with no fallback engine: the bundled CEF
OSR host is the only backend. The session type parser accepts only `x11` and
`wayland`. Unknown values fail closed instead of selecting another cell or a
fallback engine. The Dart `LinuxStandalonePresenter` and the Rust
`browser_linux_standalone` module expose the same parsing, path, geometry,
and flag vocabulary so fixtures stay aligned.

## Owned-window behavior

The presenter owns geometry, z-order, focus, input, IME, resize/DPI, popup,
and close behavior on both compositors:

- geometry (`x`, `y`, `width`, `height`, `deviceScaleFactor`, visibility)
  is validated so both cells fail closed on non-finite origins,
  non-positive sizes, or non-positive scales;
- z-order (`background`, `normal`, `foreground`) records the app's stacking
  request; `bringToFront` re-asserts focus so input routing follows the
  stacking change, while `sendToBack` releases focus;
- focus rides ordered `FocusCommand` values and window-changed events update
  the locally tracked focus so X11 and Wayland stay aligned;
- pointer, keyboard, wheel, and IME input ride ordered `InputCommand` values;
- resize and device-scale changes ride ordered `ResizeCommand` values;
- popups inherit the opener's account and privacy context as roscord-owned
  standalone child surfaces and close with the opener; they never escape
  into an unowned native window;
- close sends the typed close operation and observes the same stale-surface
  contract on a second close; close always wins, including after host loss.

Frame-ready events coalesce to the newest client-owned reference while every
other control event is preserved in order, matching the embedded presenter.
Frames carry size, stride, format, and sequence and are never CEF pointers
or borrowed CEF buffers.

## Shared account state and policy

Standalone and embedded surfaces share account state and policy. A
`MatrixWidgetAdapterLaunch` with `PresentationMode.standalone` builds the
same `SurfaceSpec` as the embedded launch except for the presentation mode:
the stable local account-record profile key, the initial widget navigation,
the declared page/parent origins, and the generic host capability flags are
identical, and Matrix capability names stay out of the host policy. Two
surfaces for one account therefore observe shared browser state on the same
host request context without starting another host, while profile mismatch
and sequence replay fail with the same error codes on both presentations.

## No child embedding or unowned windows

Native child embedding and unowned browser windows are never introduced. Both
the Dart and Rust presenters deny fallback engines, child embedding, and
unowned windows by name (case-insensitive, substring-based) and fail closed
on unknown backend names: only `cef-osr-cpu` (alias `cef`) resolves.
WebKitGTK, system CEF, external Chromium, Wry, WebView2, native child
windows, and unowned browsers are not used. Static contract checks assert the
presenter sources contain the OSR/CPU/owned-window vocabulary and none of
the fallback engine or embedding names.

## Host loss

Host loss leaves the rest of roscord usable. The presenter records a
runtime-lost observation that drops the pending frame and exposes an
accessible reconnecting state instead of crashing the Flutter application.
The surface can still be closed, and other surfaces on the same runtime
remain usable with independent command sequences.
