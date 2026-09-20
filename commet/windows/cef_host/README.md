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

The target builds `client.dll` and copies the locked `Release/bootstrap.exe` to
`cef_host.exe`.  The CEF bootstrap is the process entry point and loads the
client DLL with `--module=client.dll`; it supplies the sandbox handle to both
`CefExecuteProcess` and `CefInitialize`.  The host rejects startup when the
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
message.  Frames are capped at the BrowserRuntime limit (1 MiB).  The first
fixture `open` creates a windowless CEF browser at `commet://fixture/` and
emits `opened` followed by `event/ready`; `close` emits `event/closed` after
CEF closes the browser.  CEF-owned pointers and buffers never cross this
transport.

The fixture is a development/smoke-test surface.  It does not provide a
production fallback or a second browser engine; CEF initialization and the
same sandbox/bootstrap checks are required before it can be opened.
