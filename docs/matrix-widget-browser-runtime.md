# Matrix widgets and BrowserRuntime

`MatrixWidgetAdapter` is the contract seam between the Matrix widget protocol
and `BrowserRuntime`. It keeps Matrix-specific behavior in Dart while the CEF
host receives only the generic `SurfaceSpec`, `ScriptCommand`, and
`SurfaceEvent` values defined by BrowserRuntime.

## Launch data

`MatrixWidgetAdapterLaunch.fromMatrixWidget` builds one immutable launch
record from a `MatrixUserWidgetInfo` and `MatrixRoom`. The record preserves the
existing substitutions:

- `$matrix_user_id`, `$matrix_room_id`, and `$matrix_display_name`;
- `$org.matrix.msc3819.matrix_device_id` and
  `$org.matrix.msc4039.matrix_base_url`;
- `$chat.commet.color_scheme` and `$org.matrix.msc2873.client_theme`.

`buildWidgetUri` adds `parentUrl`, `widgetId`, `accountId`, and `profileKey` to
the URL. `profileKey` is the stable local `MatrixClient.identifier`; it is not
a Matrix user id or a homeserver URL. The generated `SurfaceSpec` carries the
same profile, presentation/privacy mode, initial navigation, allowed page and
parent origins, and capability policy.

## Widget bridge

`MatrixWidgetBrowserRuntimeTransceiver` adapts the old `WidgetTransceiver`
interface to BrowserRuntime script envelopes. Opening a session first sends a
generic `evaluate_javascript` command containing the adapter-owned bridge
script. The script is the BrowserRuntime equivalent of `widgets_ipc.js` and
the Rust `call_ipc.js` fallback: it installs the `window.parent.postMessage`
shim, recursive binary conversion, `sessionStorage` rendezvous, and the
`__roscordBrowserRuntimeReceive`/`__roscordBrowserRuntimeSend` callbacks.
Matrix vocabulary remains in the adapter and existing Matrix
message/capability handlers; `cef_host` sees only an opaque script channel and
generic script values.

The bridge intentionally retains the old wire details:

- outbound values use `chat.commet.toWidget:<counter>` storage keys;
- inbound values must use `chat.commet.fromWidget:<counter>` keys;
- each payload is an underscore-prefixed, newline-delimited UTF-8 frame;
- page/app origin checks are applied before a frame is delivered;
- recursive `ArrayBuffer` and `Blob` values are decoded by
  `MatrixWidgetTransport`, including nested lists and maps.

`MatrixWidgetBrowserRuntimeRunner` reuses `MatrixWidgetMessageHandler` and
`MatrixWidgetCapabilitiesManager`, so capability prompts, accepted/rejected
state, and the Matrix widget API continue to use their existing protocol
names and implementations. Those Matrix capability names stay in Dart; only
optional generic host policy flags are copied into `SurfacePolicy`.

## Lifecycle and platform boundaries

`MatrixWidgetAdapter` owns at most one active BrowserRuntime session. Opening a
new session is serialized with other opens and awaits deterministic disposal of
the previous one. Closing sends
the typed BrowserRuntime close operation, waits for the closed event (with a
bounded timeout), and then tears down the transceiver and event subscriptions.

This issue introduces the contract adapter; presentation work (including the
Windows and Linux OSR texture surfaces) consumes it in the follow-up issues.
Android, web, iOS, macOS, remote HTTP, and deliberate external-browser flows
continue to use their existing runners until those platform-specific
presenters migrate. The adapter does not add a fallback browser backend.
