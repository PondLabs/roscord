# Flatpak CEF artifacts, sandbox, portals, and signatures

This note qualifies the Flatpak side of the atomic BrowserRuntime cutover
(epic #110, ticket #130). The signed Flatpak artifact runs all required
Matrix presentations under GNOME Platform 48 on X11 and Wayland from its
bundled CEF payload: no host CEF, no host WebKitGTK, no GPU requirement, no
runtime download, no foreign engine, and no partially staged bundle may ship.

## Bundle layout

The Flatpak files root (`build-dir/files` at build time, `/app` at runtime)
carries the CEF payload in `cef/` (installed from the locked `linux-x64`
runtime). The install flattens the archive's `Release/` contents into the
payload root and keeps `Resources/` as a subdirectory; the Flutter bundle
stays at `commet/bundle`:

```text
<files>/cef/libcef.so
<files>/cef/chrome-sandbox           # sandbox helper (user-namespace route)
<files>/cef/libEGL.so                # graphics / software fallback
<files>/cef/libGLESv2.so
<files>/cef/libvk_swiftshader.so
<files>/cef/libvulkan.so.1
<files>/cef/v8_context_snapshot.bin
<files>/cef/vk_swiftshader_icd.json
<files>/cef/Resources/chrome_100_percent.pak
<files>/cef/Resources/chrome_200_percent.pak
<files>/cef/Resources/icudtl.dat
<files>/cef/Resources/resources.pak
<files>/cef/Resources/locales/en-US.pak (+ further staged locales)
<files>/cef/fixtures/fixture.html
<files>/commet/bundle/commet         # Flutter shell
```

`LICENSE.txt` and `CREDITS.html` are archive-root inputs and are not
installed into the payload; they ship as the generated
`THIRD_PARTY_NOTICES.txt` in the release metadata (see below). The Dart
`flatpakCefBundleRoot` (`/app`) and Rust `FLATPAK_CEF_BUNDLE_ROOT` (`/app`)
plus `FLATPAK_CEF_LIBRARY_PATH` (`/app/cef/libcef.so`) are the only
resolution roots; `resolveFlatpakCefBundlePath` rejects traversal, control
characters, empty values, and any non-`/app/` path, while `isHostCefPath`
and `isHostWebKitGtkPath` deny `/usr/lib`, `/opt`, `/run/host`, `/host`,
and any host engine name.

## Staging and metadata

Release jobs fetch and stage the exact locked pair with the release-only
`tools/cef_runtime.py` (never imported by the app, never a runtime
downloader):

```text
python tools/cef_runtime.py fetch --platform linux-x64 --cache-dir .cef-cache
python tools/cef_runtime.py stage --platform linux-x64 <archive> <staged>
python tools/cef_runtime.py metadata --platform linux-x64 <staged> <metadata>
```

`stage` copies only the lock allow-list (CEF resources, helpers, locales,
graphics dependencies, sandbox inputs, notices) and fails on any
unallow-listed file under `Release/`/`Resources/`; headers, examples, and
debug files are never user payload. `metadata` emits the signed-byte-ready
`cef.runtime.manifest.json` (per-file SHA-256),
`cef.provenance.json` (`runtime_download: false`,
`runtime_source: bundled-release-payload`), a CycloneDX 1.5
`cef.sbom.cdx.json` naming the locked CEF/Chromium tuple plus shipped native
files, and `THIRD_PARTY_NOTICES.txt`.

## Sandbox, manifest permissions, portals, and denial behavior

`cef_host` and all CEF children run as the ordinary non-elevated Flatpak
user with user-namespace and seccomp sandboxing inside GNOME Platform 48.
SUID is not assumed.

`validateFlatpakFinishArgs` pins least privilege: `ipc`, `fallback-x11`,
`wayland`, `pulseaudio`, `network`, and `dri` must be present while
`--device=all`, host/home filesystem access, host OS bindings, and
`flatpak-spawn` escapes fail closed with `policyViolation`. The manifest no
longer grants `device=all`: Flatpak camera and capture go through portals,
GPU import stays an optional optimization behind CPU `OnPaint`, and denial
never broadens the sandbox. The qualification gate re-checks the real
`chat.commet.commetapp.yaml` for the same allow/deny sets, the GNOME
Platform 48 / `x86_64` / app-id / `/app` tokens, and the absence of
broadening fragments.

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

## Qualification gate

`tools/qualify_flatpak_artifact.py` qualifies one Flatpak files root plus
its generated metadata and manifest against
`third_party/cef/cef.lock.json`:

```text
python tools/qualify_flatpak_artifact.py \
  --bundle build-dir/files --metadata .cef-metadata \
  --manifest commet/linux/flatpak/chat.commet.commetapp.yaml
python tools/qualify_flatpak_artifact.py \
  --bundle <dir> --metadata <dir> --manifest <yaml> \
  --require-signatures --output report.json
```

It verifies, in order: required CEF resources, helpers (`libcef.so`,
`chrome-sandbox`), locales (including `en-US.pak`), and graphics
dependencies are staged; payload bytes match the manifest; notices,
CycloneDX SBOM, and provenance are complete and lock-consistent; native
binaries pass hash checks (and detached `signatures.json` checks with
`--require-signatures`); the Flatpak manifest pins GNOME 48, `x86_64`, and
least-privilege finish-args with no broadening fragment; the sandbox/helper
pair is present with no bypass switch or host-escape reference in shipped
configs; no foreign backend (`webkitgtk`, `wry`, `desktop_webview_window`,
system CEF), no shipped CEF archive, and no CEF download reference; and the
SwiftShader/ANGLE inputs for forced CPU mode. Symbols (`.pdb`), import
libraries, Windows PE binaries, `bootstrapc.exe`, and debug/test trees
always fail. The release Flatpak job runs this gate after the Flatpak
build; a failure blocks the artifact.

## Embedded and standalone Matrix surfaces pass with CPU rendering

Both Flatpak cells report the same bundled paths: Flatpak X11 and Wayland
embedded use OSR/CPU frames from `/app` (`osr-cpu-flutter-texture`);
Flatpak X11 and Wayland standalone use OSR/CPU frames from `/app` inside a
roscord-owned window (`osr-cpu-owned-window`), with no native Wayland child
embedding. `resolveFlatpakBackend` accepts only `cef-osr-cpu` (alias `cef`);
GPU-only names fail so CPU rendering stays release-authoritative. Both
presenters only construct with `FlatpakRendering.cpuOsr`; frames carry size,
stride, format, and sequence and are never CEF pointers or borrowed buffers;
the frame budget mirrors the wire limit and over-budget frames fail closed.
The qualification gate scans the bundle for foreign-backend filenames,
shipped CEF archives, and download references, so a clean Flatpak runtime
without host CEF, host WebKitGTK, or GPU availability still opens every
required surface from the bundle.

## Signing and provenance

Production signs the OSTree repository/commit and the standalone
`.flatpak` bundle plus manifests, SBOM, and notices with the project
release key as detached sidecars. The auditable record is
`metadata/signatures.json`:

```json
{"version": 1, "algorithm": "release-key", "files": {"libcef.so": "<sha256>"}}
```

Every payload native binary (every `*.so`/`*.so.*` plus `chrome-sandbox`)
must have an entry whose SHA-256 matches the staged bytes. `metadata`
additionally carries `cef.runtime.manifest.json`,
`cef.provenance.json` (`runtime_download: false`,
`runtime_source: bundled-release-payload`), CycloneDX 1.5
`cef.sbom.cdx.json`, and `THIRD_PARTY_NOTICES.txt`, all lock-consistent.
Any signing or provenance failure blocks publication of the complete
Windows/Linux release.
