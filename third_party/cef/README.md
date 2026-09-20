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
