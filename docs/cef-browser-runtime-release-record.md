# Signed atomic release record

This note defines the final gate artifact for the BrowserRuntime cutover
(epic #110, ticket #133). Release maintainers publish or reject one complete
desktop release from one signed JSON record. The record is produced and
checked by `tools/release_record.py` (never imported by the app, never a
runtime downloader, standard library only).

## Atomic set

The record covers one Windows x64 artifact plus every released Linux x64
artifact together:

- `windows-x64` (`roscord-windows.zip`);
- `debian-12` (Debian 12 baseline `.deb`);
- `ubuntu-22.04` and `ubuntu-24.04` (released Ubuntu `.deb`s);
- `portable` (`roscord-linux-portable-x64.tar.gz`);
- `flatpak` (`chat.commet.commetapp.flatpak`, GNOME Platform 48 `x86_64`).

`tools/release_record.py --list-packages` prints this set. Any missing or
failing section blocks publication of the entire Windows/Linux set: Windows
and all released Linux artifacts are published or withheld together. There is
no Windows-only or Linux-only release.

## Record contents

`tools/release_record.py --example` emits a passing template. Every field
below is mandatory:

- `release_version`: the single version every package carries (for example
  `v1.2.3-atomic.1`). A package whose `version` differs from the record
  blocks the candidate.
- `cef_lock`: the exact lock tuple from `third_party/cef/cef.lock.json` —
  CEF `152.0.8+g1ce985c+chromium-152.0.7977.134`, branch `7977`, Chromium
  `152.0.7977.134`, `standard` distribution, both archive filenames/URLs/
  sizes, upstream SHA-1 sidecars
  (`fcefc344…` Windows, `add0a51f…` Linux), project SHA-256 digests, raw
  manifest digests, and the `runtime_download: false` / `CycloneDX-1.5`
  policy. A mixed tuple, moving URL, or placeholder digest fails closed.
- `manifests`: raw and staged manifest SHA-256 digests plus file counts for
  `windows-x64` and `linux-x64`. The raw digest must match `cef_lock`; the
  staged digest must match `cef.runtime.manifest.json` from
  `tools/cef_runtime.py metadata`.
- `sandbox_bootstrap`: the Windows bootstrap pair (`cef_host.exe`,
  `client.dll`, `chrome_elf.dll`), the Linux sandbox pair (`libcef.so`,
  `chrome-sandbox`), `bypass_flags_absent`, and `sandbox_info_forwarded`.
  `--no-sandbox`, `--disable-web-security`, `--allow-file-access-from-files`,
  and `--remote-debugging-port` must be absent from every shipped config.
- `notices_sbom`: `THIRD_PARTY_NOTICES.txt` present, CycloneDX 1.5 SBOM
  naming the locked CEF/Chromium tuple plus shipped native files,
  `provenance_bundled` (`runtime_download: false`,
  `runtime_source: bundled-release-payload`).
- `signatures`: detached release-key sidecars. With `--require-signatures`
  every package needs `{"signed": true, "sha256": "<digest>"}` matching its
  staged bytes, and `signatures.record.record_sha256` must equal
  `record_digest(record)` (canonical JSON SHA-256 over everything except
  `signatures`). Production additionally signs Windows PE binaries with
  Authenticode, Debian repository metadata and directly distributed packages,
  and the Flatpak OSTree repository/commit plus standalone bundle; any
  signing failure blocks publication. `signatures.json` is the auditable
  record the per-package qualifiers verify.
- `packages`: one entry per atomic artifact with `artifact`, `version`,
  `status: pass`, and a real `artifact_sha256`. Each entry is backed by its
  qualifier report: `tools/qualify_windows_artifact.py` (Windows),
  the Dart `linux_artifact_qualification.dart` / Rust
  `browser_linux_artifacts` fixtures (native Debian/Ubuntu/portable), and
  `tools/qualify_flatpak_artifact.py` (Flatpak).
- `matrix`: the embedded `tools/qualify_release_candidate.py` report
  (`cells`, `faults`, `perf`, `manual`, `forbidden`). The release record
  delegates to that gate: 23 mandatory G cells, 11 preserved P flows, 5 N/A
  boundaries, 5 prohibited X markers, 230 fault records (10 families x 23
  cells), performance thresholds, and 7 manual topics must all pass.
- `failure_traces`: one passing trace per `family:cell` key. Each entry
  carries `status: pass`, a `trace` reference, its `artifact` and hash, the
  locked CEF version, OS/compositor/presentation, ordered events, command
  outcomes, metric/log deltas, dump sidecar or explicit no-dump result,
  screenshots, `forbidden_backends_absent: true`, and
  `side_effects_replayed: false`.
- `negative_backend`: every prohibited marker `absent` (`webview2`,
  `webkitgtk-wry-runner`, `system-cef`, `runtime-cef-download`,
  `unowned-browser`), plus `validation_switch_absent`,
  `fault_injection_disabled`, `runtime_download_absent`,
  `sandbox_bypass_absent`, `clean_smoke_pass`, and `target_scan: pass`.
  Target-scoped scans prove no WebView2/WebKitGTK/Wry runner, no
  `desktop_webview_window` registration, no system CEF lookup, no external
  CEF download, no production validation/fallback flag, no sandbox or
  permission bypass, and no host CEF dependency. A clean image with legacy
  engines, host CEF, and relevant system libraries unavailable must still
  open all required CEF G cells from the bundle.

## Gate behavior

```text
python tools/release_record.py --example > release.json
python tools/release_record.py --report release.json --require-signatures
python tools/release_record.py --self-check
python -m unittest tools.test_release_record
```

`evaluate` returns `passed`, `failures`, and `counts`; `qualify` raises
`ReleaseBlocked` on failure. `--self-check` proves the example passes and a
single failed package blocks. The signed gate report carries `record_sha256`,
the `published or withheld together` rule, and the complete-set rollback
rule. One failed mandatory cell, preserved flow, package, trace, signature,
or negative-backend check blocks the candidate.

## Publication rule

The release workflows build every desktop artifact from the same commit and
lock, run every per-package qualifier, then run this gate. Uploads happen
only after the gate passes; otherwise every artifact is withheld. See
`docs/cef-browser-runtime-release-candidate.md` for the matrix gate and
`docs/cef-browser-runtime-rollback.md` for the rollback half of the atomic
rule.
