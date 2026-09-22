# Native Linux embedded Matrix surfaces

Native Linux Matrix widgets render inside Flutter on both required compositor
cells (native X11 and native Wayland) through one shared presenter: CEF
windowless/off-screen rendering with CPU `OnPaint` copied into client-owned
memory and presented as a Flutter texture.

## Compositor cells

Both cells report the same presentation path, `osr-cpu-flutter-texture`:
- native X11 uses OSR/CPU frames and the Flutter texture path;
- native Wayland uses OSR/CPU frames and the Flutter texture path, with no
  native Wayland child embedding.

Both cells use forced cpu rendering with no fallback engine: the bundled CEF
OSR host is the only backend.

The session type parser accepts only `x11` and `wayland`. Unknown values fail
closed instead of selecting another cell or a fallback engine. The Dart
`LinuxEmbeddedPresenter` and the Rust `browser_linux_embedded` module expose
the same parsing, path, and flag vocabulary so fixtures stay aligned.

## Windows parity

The presenter is runtime-agnostic and attaches to the same four-operation
`BrowserRuntime` seam as Windows. A `MatrixWidgetAdapterLaunch` with
`PresentationMode.embedded` builds the same `SurfaceSpec` on Linux as on
Windows: the stable local account-record profile key, the initial widget
navigation, the declared page/parent origins, and the generic host capability
flags. Matrix capability names stay in the adapter.

Command behavior matches Windows command for command:

- pointer, keyboard, wheel, and IME input ride ordered `InputCommand` values;
- resize and device-scale changes ride ordered `ResizeCommand` values;
- focus rides ordered `FocusCommand` values;
- close sends the typed close operation and observes the same stale-surface
  contract on a second close;
- profile mismatch and sequence replay fail with the same error codes;
- navigation policy (allowed origins, loopback, external routing) is shared,
  so undeclared URLs stay blocked on both platforms.

Frame-ready events coalesce to the newest client-owned reference while every
other control event is preserved in order, matching the Windows texture
adapter. Frames carry size, stride, format, and sequence and are never CEF
pointers or borrowed CEF buffers.

## Forced CPU rendering

CPU/OSR is the release-authoritative path. The presenter only constructs with
`LinuxEmbeddedRendering.cpuOsr`; accelerated imports (dma-buf or otherwise)
remain gated experiments and are never required. Forced software rendering
therefore satisfies the same contract on Wayland without introducing a native
child window.

## No fallback engines

WebKitGTK, system CEF, external Chromium, Wry, WebView2, and unowned browsers
are not used. Both the Dart and Rust presenters deny them by name
(case-insensitive, substring-based) and fail closed on unknown backend names:
only `cef-osr-cpu` (alias `cef`) resolves. Static contract checks assert the
presenter sources contain the OSR/CPU/texture vocabulary and none of the
fallback engine names.
