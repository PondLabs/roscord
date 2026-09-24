# Windows `cef_host`

This directory contains the Windows CEF bootstrap client for the
`BrowserRuntime` contract.  It is intentionally not part of the default
Flutter build.  A native build first verifies the exact Windows archive from
`third_party/cef/cef.lock.json`, then stages the build-only SDK directory:

```text
python tools/cef_runtime.py verify --platform windows-x64 <cef-archive>
python tools/cef_runtime.py stage-sdk --platform windows-x64 <cef-archive> <cef-sdk>
cmake -DROSCORD_BUILD_CEF_HOST=ON -DCEF_ROOT=<cef-sdk> ...
```

`stage-sdk` is the only supported `CEF_ROOT` input.  It combines the locked
headers, CMake files, wrapper sources, import libraries, and allow-listed
runtime files for compilation; the SDK directory is a build input and is not
copied into the shipped Flutter bundle.  The ordinary `stage` command remains
the release-payload staging path and intentionally omits the SDK.

The target builds `cef_host.dll` and copies the locked `Release/bootstrap.exe`
to `cef_host.exe`.  The CEF bootstrap is the process entry point.  Renamed, it
loads the DLL named after itself from its own directory (`--module` only
applies while it is still called `bootstrap.exe`), and both must be signed
with the same certificate or both be unsigned.  It supplies the sandbox handle
to both `CefExecuteProcess` and `CefInitialize`.  The host rejects startup when the
bootstrap/client inputs, bundled CEF modules/resources, parent process, or
authenticated pipe cannot be verified.  It never downloads CEF and never
uses a system CEF installation.

The parent application owns a per-instance nonce and passes a private pipe
name like this to the host; the host creates the owner-only server endpoint
and the parent connects to it:

```text
\\.\pipe\roscord-browser-<parent-pid>-<hex-nonce>
```

The host validates the pipe prefix, parent PID, same-user token, nonce,
protocol version, and a four-byte big-endian length prefix before accepting a
message.  Frames are capped at the BrowserRuntime limit (1 MiB).  An `open`
creates an embedded windowless or standalone owned CEF browser at the
caller-declared URL and emits `opened` followed by `event/ready`; `close`
emits `event/closed` after CEF closes the browser.  Navigation, redirects,
TLS errors, and popups are mediated by the surface policy; CEF-owned pointers
and buffers never cross this transport.  The pipe uses overlapped I/O, so
events go out while a read is pending.

Embedded surfaces paint into a shared-memory frame ring (a named file
mapping, `Local\roscord-cef-...`) that the app's `browser_surface` plugin
draws into a Flutter texture; `frame_ready` names the ring and slot.  Input
arrives as W3C key codes and Flutter pointer buttons and is translated with
`browser_surface/native/browser_input.h`.  See
[`docs/cef-browser-runtime-hosts.md`](../../../docs/cef-browser-runtime-hosts.md),
which also covers `tools/cef_host_smoke.py`, the smoke test CI runs against
the built bundle.

The fixture is a development/smoke-test surface.  It does not provide a
production fallback or a second browser engine; CEF initialization and the
same sandbox/bootstrap checks are required before it can be opened.

The parent also passes an owner-controlled `--profile-root` below the Windows
local app-data directory.  `ProfileManager` maps each stable local account
record to a generated directory and owner-only manifest, shares one
persistent `CefRequestContext` for that account, and creates a new empty
request context for every private surface.  Reparse points, traversal,
outside-root paths, and non-owner manifests are rejected.  Missing or
mismatched manifests are moved to `quarantine-*` and reported as migration
failures; no legacy browser directory is imported.  Clear-data is exposed to
the account-data bridge only after all account surfaces are quiescent and
preserves committed downloads.

Navigation and popup policy details, including the exact HTTPS/loopback rules
and fail-closed certificate handling, live in
[`docs/cef-browser-runtime-navigation.md`](../../../docs/cef-browser-runtime-navigation.md).

Camera, microphone, and screen-capture mediation, including scoped grants,
fresh display consent, and portal outcomes, live in
[`docs/cef-browser-runtime-media.md`](../../../docs/cef-browser-runtime-media.md).
