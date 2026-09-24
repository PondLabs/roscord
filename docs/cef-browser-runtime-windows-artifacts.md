# Windows CEF artifacts, sandbox, and signatures

This note qualifies the Windows side of the atomic BrowserRuntime cutover
(epic #110, ticket #128).  Windows ZIP and portable artifacts run from their
bundled, signed CEF payload on a clean machine: no host CEF, no runtime
download, no foreign engine, and no partially staged bundle may ship.

## Bundle layout

The Windows `Release` directory next to `commet.exe` carries the CEF payload
in `cef_host/` (installed by `commet/windows/cef_host/CMakeLists.txt` when
`ROSCORD_BUILD_CEF_HOST=ON`); this nested layout is also what
`WindowsBrowserRuntime._resolveHostExecutable` prefers.  The CMake install
flattens the archive's `Release/` contents into the payload root, renames the
locked `Release/bootstrap.exe` to `cef_host.exe`, keeps `Resources/` as a
subdirectory, and adds the project-built `cef_host.dll` plus the smoke-test
fixtures. A renamed bootstrap loads the DLL named after itself from its own
directory; `--module` only applies while it keeps the name `bootstrap.exe`:

```text
<Release>/cef_host/cef_host.exe        # renamed locked bootstrap.exe
<Release>/cef_host/cef_host.dll        # project-built bootstrap client
<Release>/cef_host/libcef.dll
<Release>/cef_host/chrome_elf.dll
<Release>/cef_host/d3dcompiler_47.dll  # graphics / software fallback
<Release>/cef_host/dxcompiler.dll
<Release>/cef_host/dxil.dll
<Release>/cef_host/libEGL.dll
<Release>/cef_host/libGLESv2.dll
<Release>/cef_host/v8_context_snapshot.bin
<Release>/cef_host/vk_swiftshader.dll
<Release>/cef_host/vk_swiftshader_icd.json
<Release>/cef_host/vulkan-1.dll
<Release>/cef_host/Resources/chrome_100_percent.pak
<Release>/cef_host/Resources/chrome_200_percent.pak
<Release>/cef_host/Resources/icudtl.dat
<Release>/cef_host/Resources/resources.pak
<Release>/cef_host/Resources/locales/en-US.pak (+ further staged locales)
<Release>/cef_host/fixtures/fixture.html
```

`LICENSE.txt` and `CREDITS.html` are archive-root inputs and are not
installed into the payload; they ship as the generated
`THIRD_PARTY_NOTICES.txt` in the release metadata (see below).

## Staging and metadata

Release jobs fetch and stage the exact locked pair with the release-only
`tools/cef_runtime.py` (never imported by the app, never a runtime
downloader):

```text
python tools/cef_runtime.py fetch --platform windows-x64 --cache-dir .cef-cache
python tools/cef_runtime.py stage-sdk --platform windows-x64 <archive> <cef-sdk>
python tools/cef_runtime.py stage --platform windows-x64 <archive> <staged> \
  --project-root <app-root>
python tools/cef_runtime.py metadata --platform windows-x64 <staged> <metadata> \
  --project-root <app-root>
```

`stage` copies only the lock allow-list (CEF resources, bootstrap,
helpers, locales, graphics dependencies, sandbox inputs, notices) and fails
on any unallow-listed file under `Release/`/`Resources/`; headers, examples,
debug files, and `bootstrapc.exe` are never user payload.  `metadata`
emits the signed-byte-ready `cef.runtime.manifest.json` (per-file SHA-256),
`cef.provenance.json` (`runtime_download: false`,
`runtime_source: bundled-release-payload`), a CycloneDX 1.5
`cef.sbom.cdx.json` naming the locked CEF/Chromium tuple plus shipped native
files, and `THIRD_PARTY_NOTICES.txt`.

## Signatures

Production signs the PE binaries (`cef_host.exe`, `cef_host.dll`, `libcef.dll`,
`chrome_elf.dll`, and the remaining shipped DLLs) with Authenticode, and the
Windows ZIP, portable archive, manifests, SBOM, and notices with the project
release key as detached sidecars.  The auditable record is
`metadata/signatures.json`:

```json
{"version": 1, "algorithm": "release-key", "files": {"cef_host.exe": "<sha256>"}}
```

Every payload PE binary must have an entry whose SHA-256 matches the staged
bytes.  Any signing failure blocks publication of the complete
Windows/Linux desktop set.

## Qualification gate

`tools/qualify_windows_artifact.py` qualifies one built bundle plus its
generated metadata against `third_party/cef/cef.lock.json`:

```text
python tools/qualify_windows_artifact.py \
  --bundle commet/build/windows/x64/runner/Release \
  --metadata .cef-metadata
python tools/qualify_windows_artifact.py \
  --bundle <dir> --metadata <dir> --require-signatures --output report.json
```

It verifies, in order: required CEF resources, the bootstrap/client pair,
helpers, locales (including `en-US.pak`), graphics dependencies, and sandbox
inputs are staged; payload bytes match the manifest (with the
`bootstrap.exe` -> `cef_host.exe` rename and the `cef_host.dll` project entry);
notices, CycloneDX SBOM, and provenance are complete and lock-consistent;
native binaries pass hash checks (and detached `signatures.json` checks with
`--require-signatures`); the sandbox/bootstrap pair is present with no
bypass switch in shipped configs; no foreign backend (`WebView2Loader.dll`,
`desktop_webview_window`, Wry, WebKitGTK), no shipped
CEF archive, and no CEF download reference; and the SwiftShader/ANGLE/Direct3D
inputs for forced CPU mode.  Symbols (`.pdb`), import libraries,
`bootstrapc.exe`, and debug/test trees always fail.  The desktop-build and
release workflows run this gate after the Windows build; a failure blocks the
artifact.

The `flutter_inappwebview_windows` plugin name still appears in the bundle
(it now denotes the cutover stub in
`third_party/flutter_inappwebview_windows_stub/`, a no-op native registration
with no engine), so the filename gate no longer flags that name. Instead the
gate scans every app-side binary outside the manifest-pinned CEF payload for
engine-evidence bytes (`CreateCoreWebView2`, `EdgeWebView2`,
`WebView2Loader`, `Microsoft.Web.WebView2`): the stub passes only when its
bytes are clean, and any other binary carrying those markers fails closed.

## Sandbox and bootstrap failures block opening

`cef_host` (M138+ `bootstrap.exe` + `cef_host.dll` exporting `RunWinMain`)
forwards the bootstrap sandbox information to both `CefExecuteProcess` and
`CefInitialize`, runs with `settings.no_sandbox = false`, and refuses to
serve surfaces when the check fails:

| Failure | Behavior |
| --- | --- |
| `sandbox_info == nullptr` | Host exits before `CefInitialize`; Dart reports `hostStartFailure`. |
| Any required payload file missing (`VerifyBundledRuntime`) | Host exits; nothing opens. |
| `libcef.dll`/`chrome_elf.dll` not loaded from the bundled host directory (`VerifyLoadedBundledRuntime`) | Host shuts down after `CefInitialize`; nothing opens. |
| Invalid `--profile-root`, bad pipe/nonce/parent-PID | Argument validation fails; host exits. |
| `cef_host.exe` absent from the bundle | `WindowsBrowserRuntime` throws a `protocol` error naming the bundled path before spawning anything. |

Sandbox/bootstrap startup failures therefore block opening: no surface event
is emitted and the recovery UI offers Retry browser / Close with a diagnostic
ID, never another engine.

## No host CEF or runtime downloads

Embedded Matrix (`EmbeddedBrowserSurface`), standalone Matrix
(`StandaloneBrowserSurface`), and Windows official video (`MediaEmbedAdapter`
via `mediaEmbedUsesCef`) all construct surfaces through the `BrowserRuntime`
seam owned by the one lazily started `cef_host`.  The host loads only the
bundled `libcef.dll`/`chrome_elf.dll` (path-checked after load), the app
links no system CEF, and only `tools/cef_runtime.py` references the locked
builder origin.  The qualification gate scans the bundle for foreign-backend
filenames, shipped CEF archives, and download references, so a clean machine
without host CEF, WebView2, or system browser libraries still opens every
required surface from the bundle.

## Forced CPU mode remains functional

Passing `forceSoftwareRendering` through `WindowsBrowserRuntime` starts the
host with `--cef-software-rendering`; the host appends `disable-gpu` and
`disable-gpu-compositing` while keeping the same CPU OnPaint frame ring,
input, resize, focus, and close contract (embedded), and software windowed
rendering (standalone).  No alternate engine is selected.  The staged
SwiftShader (`vk_swiftshader.dll`, `vk_swiftshader_icd.json`), ANGLE
(`libEGL.dll`, `libGLESv2.dll`), Vulkan loader, and Direct3D compilers are
part of both the host startup gate and the qualification gate, so forced CPU
mode cannot silently lose its fallback payload.
