# CEF security cadence

This note owns the release-owned CEF/Chromium refresh policy for the
BrowserRuntime cutover (epic #110, ticket #133). The pinned lock is
`third_party/cef/cef.lock.json`: CEF
`152.0.8+g1ce985c+chromium-152.0.7977.134`, branch `7977`, Chromium
`152.0.7977.134`, official Spotify builder standard distributions for
Windows x64 and Linux x64, `proprietary_codecs: false`, Chromium/default
FFmpeg branding. Windows and every Linux artifact use one tuple; no latest
alias, semver range, branch head, runtime download, unreviewed mirror,
system/host CEF, or mixed milestone is allowed.

## Watcher and triage

A daily watcher checks the CEF builder and Chromium feeds for a supported
security release. Maintainers triage weekly. A branch without support or
without a matching Windows/Linux pair is a hard failure: the desktop release
stops rather than shipping a partial pair.

## Refresh SLA

The lock policy (`refresh_max_days`, `high_severity_refresh_hours`,
`high_severity_release_hours`, `lower_severity_release_days`) is enforced by
`tools/cef_runtime.py validate-lock` and restated here:

- Refresh the supported lock at least every 28 calendar days or for every
  supported security release, whichever comes first.
- For high/critical or actively exploited issues, start a refresh within 24
  hours and publish the complete Windows/Linux set within 72 hours after a
  fixed official pair is available.
- Lower-severity fixes ship within 7 days or the next release.

Every refresh re-qualifies both platform archives together (sidecar SHA-1,
project SHA-256, raw/staged manifests, resources/locales/sandbox/bootstrap,
notices, CycloneDX SBOM, signatures) and rebuilds every package from the
same commit and lock before the atomic gate
(`tools/release_record.py`) may pass.

## Hard stops

If a fixed pair or its qualification is unavailable, stop the desktop
release. Never self-build a one-off emergency runtime, never mix
milestones, never disable sandboxing, and never fall back to a legacy
engine (WebView2, WebKitGTK/Wry, system CEF, runtime download, unowned
browser). A minimal archive variant is allowed only after an allow-list
test proves no helper, resource, locale, sandbox file, notice, or required
runtime file was dropped.

AAC, H.264, and H.265 support requires a separate legal/product decision;
the lock keeps `proprietary_codecs: false` until then. Exact-build crash
symbols are published separately with access control.

## Where the cadence is enforced

- `tools/cef_runtime.py` fetches only the locked HTTPS origin, rejects
  redirects and unsafe extraction, and verifies digests and manifests.
- `tools/qualify_windows_artifact.py`,
  `tools/qualify_flatpak_artifact.py`, and the native
  Dart (`linux_artifact_qualification.dart`) / Rust
  (`browser_linux_artifacts`) fixtures prove the same-version payload ships
  in every final package.
- `tools/qualify_release_candidate.py` blocks a candidate whose lock,
  matrix, faults, perf, manual evidence, or forbidden backends fail.
- `tools/release_record.py` binds the exact lock/hashes, manifests,
  sandbox/bootstrap checks, notices, SBOM, signatures, package evidence,
  matrix reports, failure traces, and negative-backend proof into the one
  signed record that authorizes publication of the whole set.
