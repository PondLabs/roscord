# CEF BrowserRuntime profiles and privacy

Desktop CEF state is owned by the `cef_host` process.  The profile key passed
in `SurfaceSpec` is the stable local account-record identity used by the
Matrix client (`MatrixClient.identifier`).  It is opaque to the host: user
ids, homeserver URLs, display names, and URL-derived strings are not profile
keys.

## Persistent account contexts

The host hashes the key into a generated `profile-<digest>` directory below
the platform app-data profile root.  A private, owner-only manifest binds the
directory to schema `1` and the encoded key.  The host rejects traversal,
symlinks or Windows reparse points, outside-root paths, and profile or
manifest access that is not owner-controlled.  Legacy WebView2, WebKitGTK,
Wry, and external-Chromium directories are outside this root and are never
read or imported.

There is one persistent request context per account and host.  Embedded and
standalone surfaces for the same account receive that context, so cookies,
HTTP cache, local storage, IndexedDB/Cache Storage, service workers,
credentials, and browser permission/content settings remain account-local.
Contexts for different account-record keys are never shared.  The global CEF
context is not used.

## Private surfaces

`PrivacyMode.private` creates a fresh request context with an empty cache path
and persistence disabled.  Its context id is not entered in the persistent
registry and is destroyed after its last surface closes.  Private browser
state is never written under the profile root; a user-approved download is a
normal user file and is not removed just because the private context closes.

## Clear-data transition

The host account-data bridge calls `HostCore::clear_data` after all surfaces
and child popups for the account have closed.  A live lease returns
`profile_busy`; new opens are rejected while a clear is in progress.  The host
flushes cookies, clears certificate and HTTP-auth decisions, closes active
connections, releases the old request context, and only then traverses the
profile directory.  It deletes browser-owned files without following links,
keeps the bound manifest and a committed `downloads` directory, and validates
the fresh profile before reporting success.  Matrix databases, Matrix
credentials, app preferences, and committed downloads are outside this
operation.

## Migration and quarantine

Only a profile with an exact roscord manifest can be opened.  A missing,
mismatched, unsupported, corrupt, linked, or non-owner manifest is moved to a
generated `quarantine-*` directory and produces a migration-failed/profile
failure.  Its bytes are retained for diagnosis; the host never guesses,
merges, silently resets, or imports legacy browser data.  Crash recovery also
does not delete or reset a profile.

The Rust host registry and the Windows CEF request-context manager implement
the same rules.  Their tests cover same-account sharing, cross-account
isolation, private ephemerality, quiescent clear-data, download preservation,
unsafe paths, and quarantine without reset.
