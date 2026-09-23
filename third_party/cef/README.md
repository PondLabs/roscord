# Locked CEF inputs

`cef.lock.json` is the release-owned source of truth for the CEF runtime used
by Windows x64 and Linux x64.  Both records point at the same CEF/Chromium
tuple and use the official Spotify CEF builder **standard** distributions.
The archive SHA-1 values are the upstream sidecar values; the SHA-256 values
and raw-file manifest digests were computed independently and are checked
before anything is staged.

The release-only tool is `tools/cef_runtime.py`.  It has no application
dependency and is never imported by the Flutter or native runtime:

```text
python tools/cef_runtime.py validate-lock
python tools/cef_runtime.py fetch-pair --cache-dir .cache/cef
python tools/cef_runtime.py fetch --platform windows-x64 --cache-dir .cache/cef
python tools/cef_runtime.py verify --platform windows-x64 <archive>
python tools/cef_runtime.py stage --platform windows-x64 <archive> <runtime-dir> \
  --project-root <app-root>
python tools/cef_runtime.py metadata --platform windows-x64 <runtime-dir> <metadata-dir> \
  --project-root <app-root>
```

Fetching is content-addressed by the locked project SHA-256.  It fetches only
the exact HTTPS URL and its matching `.sha1` sidecar, rejects redirects, and
verifies the archive size, sidecar SHA-1, project SHA-256, and extracted raw
manifest before returning.  A cache is only an optimization; it cannot change
the lock or provide an alternate source.

Extraction rejects absolute paths, traversal, duplicate/case-colliding names,
symlinks, hard links, device files, and FIFOs.  Staging copies only the
platform's allow-listed Release/Resources files, locales, sandbox/bootstrap,
license, and credits inputs, and fails on an unallow-listed file in those
runtime directories.  Headers, examples, tests, debug files, and
`bootstrapc.exe` are never user payload.  When `--project-root` is supplied,
the lock-listed app bootstrap files (such as `client.dll`) must each match
exactly one regular file and are recorded in the generated metadata.  The
generated metadata directory
contains:

* `cef.runtime.manifest.json` — the staged file hashes and locked provenance;
* `cef.provenance.json` — source, tuple, archive, and raw/staged manifest
  evidence;
* `cef.sbom.cdx.json` — a CycloneDX 1.5 SBOM for CEF, Chromium, and shipped
  native files; and
* `THIRD_PARTY_NOTICES.txt` — the upstream CEF license and credits material.

The tool is intentionally not a runtime downloader.  Signing the final
manifests, native binaries, and packages happens in the downstream artifact
qualification gate; a signing or qualification failure must withhold the
complete Windows/Linux release.

## Linux host

Linux and Flatpak use the bundled `cef_host` executable as the one CEF process
owner. The parent starts it with an absolute, staged runtime and profile root:

```text
cef_host \
  --socket "$XDG_RUNTIME_DIR/roscord/cef-host-<nonce>.sock" \
  --parent-pid "$PPID" \
  --parent-nonce "$NONCE" \
  --cef-root "/path/to/bundle/cef" \
  --profile-root "$XDG_DATA_HOME/roscord/browser-profiles"
```

The host rejects elevated launches, sandbox-bypass flags, missing or
symlinked CEF inputs, system-library lookup, insecure profile/socket roots,
and a pre-existing endpoint. It authenticates the connecting process with
Linux peer credentials and authenticates every length-framed message with the
parent nonce and protocol version. The ordinary-user user-namespace sandbox
route is accepted when the kernel permits it; no native Wayland child
embedding is required.

The Linux CMake build needs a full CEF SDK for the C API bridge and a staged
runtime for packaging; the staged runtime intentionally contains no headers.
Like the Windows host it is opt-in, and because the Flutter tool passes no
`-D` options, all three settings are read from the environment too:

```text
ROSCORD_BUILD_CEF_HOST=ON \
ROSCORD_CEF_SDK_ROOT=/path/to/cef-sdk \
ROSCORD_CEF_RUNTIME_DIR=/path/to/staged/cef \
  flutter build linux --release
```

`cef_host` opens `Release/libcef.so` from the explicit `--cef-root` at
runtime. It has no link-time or system CEF dependency, and a build without the
SDK bridge fails closed when launched.

CEF's shared executable entry point is run before the host opens its socket,
so renderer/GPU/utility child invocations cannot accidentally become another
transport owner. Open and close are exposed as `opened`, `ready`, and
`closed` BrowserRuntime events; malformed, oversized, stale, and
profile-mismatched messages fail closed.
