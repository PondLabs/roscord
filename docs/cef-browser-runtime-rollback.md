# Atomic rollback and profile safety

This note defines the rollback half of the atomic BrowserRuntime cutover
(epic #110, ticket #133). Rollback withdraws/stops the complete desktop set
and installs the last known-good complete application release. It is checked
by `tools/rollback_release.py` (release tooling only, standard library
only).

## Complete-set rule

Rollback covers the same six artifacts as the release record:

- `windows-x64`, `debian-12`, `ubuntu-22.04`, `ubuntu-24.04`, `portable`,
  `flatpak` (`tools/rollback_release.py --list-artifacts`).

The plan carries `candidate_version` (the withdrawn bad release) and
`last_known_good_version` (the complete release to restore). Every artifact
must have `withdrawn: true` and `stopped: true` in `withdrawal`, and
`installed: true` with matching `version` and a real `artifact_sha256` in
`install`. A Windows-only or Linux-only rollback fails closed, as does any
missing artifact, hash, or version skew. The two versions must differ.

```text
python tools/rollback_release.py --example > rollback.json
python tools/rollback_release.py --plan rollback.json
python tools/rollback_release.py --self-check
python -m unittest tools.test_rollback_release
```

`--self-check` proves the example passes and a single un-withdrawn artifact
blocks. The gate report restates the atomic rule: withdraw/stop together,
install the last known-good complete release together.

## No legacy engine revival

The `engines` section must list every prohibited marker as `absent`
(`webview2`, `webkitgtk-wry-runner`, `system-cef`, `runtime-cef-download`,
`unowned-browser`). A rollback that revives WebView2, WebKitGTK/Wry, a
system or runtime-downloaded CEF, or an unowned browser fails closed. The
restored release is the same CEF-only desktop graph the cutover deleted to:
`tools/release_record.py` negative-backend proof applies to the rollback
target as well.

## CEF and legacy profile roots stay separate

The `profiles` section binds two roots:

- `cef_root`: the CEF profile root holding generated `profile-<digest>`
  directories with owner-only manifests (see
  `docs/cef-browser-runtime-profiles.md`).
- `legacy_root`: the untouched WebView2/WebKitGTK/Wry directories, never
  written by the new runtime.

The gate requires `separate: true` with distinct non-empty paths,
`downgrade_migrator: false`, `silent_deletion: false`,
`quarantine_retained: true`, and `legacy_imported: false`. Concretely:

- The first CEF open creates a fresh account-bound profile; legacy profile
  directories remain untouched and unwritable by the new runtime.
- Binary rollback keeps separate CEF and legacy roots: a rolled-back old
  build does not see CEF state, and the CEF release retains it for a later
  forward release.
- No downgrade migrator exists and no automatic data deletion runs. Corrupt,
  mismatched, or unsupported profiles quarantine to `quarantine-*` and report
  migration-failed/re-authentication; bytes are retained for diagnosis.
  Crash recovery never deletes or silently resets a profile.
- WebView2, WebKitGTK, Wry, and external-Chromium data is never imported.

## Rehearsal

Manual rollback rehearsal (withdraw the complete set, install the last
known-good complete release) is a required manual-evidence topic in the
matrix gate (`docs/cef-browser-runtime-release-candidate.md`). The rehearsal
record names the withdrawn candidate, the restored version, per-artifact
hashes, the ordered withdraw/stop/install events, and proof that no legacy
engine loaded and no profile was migrated or deleted.
