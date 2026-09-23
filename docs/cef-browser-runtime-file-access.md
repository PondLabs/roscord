# CEF BrowserRuntime file access: downloads, clipboard, uploads

Files and clipboard access require explicit app decisions and safe staging.
The page never receives a native clipboard handle, a real filesystem path, or
a directory enumeration. Every pending request cancels terminally on
navigation, close, host loss, timeout, denial, or unavailable UI.

The pure policy lives in two mirrored implementations:

- Dart: `commet/lib/browser_runtime/file_access.dart`
- Rust: `rust/rust/src/browser_file_access.rs`

The Windows `cef_host` (`commet/windows/cef_host/cef_host.cpp`) and the Linux
`cef_host` (`rust/rust/src/cef_host.rs` via `HostCore`) enforce the same
policy at their CEF callbacks. Wire vocabulary is shared: `download_request`,
`clipboard_request`, and `upload_request` events with matching `download`,
`clipboard`, and `upload` commands.

## Downloads

1. `OnBeforeDownload` cancels the inline CEF download synchronously and emits
   one `download_request` carrying the URL and the sanitized suggested name.
   Nothing is written before the app decides.
2. The app approves with `AcceptDownload(destination)` where `destination` is
   a leaf name inside the safe account/user destination (the account profile's
   `downloads` directory or the OS user download directory bound to that
   account). Approval requires an explicit user action in app UI.
3. The host validates the leaf with `SanitizeDownloadName` (Dart
   `sanitizeSuggestedDownloadName`, Rust `sanitize_suggested_download_name`):
   empty names, traversal, separators, drive prefixes, control characters, dot
   segments, reserved device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`,
   `LPT1`–`LPT9`), and overlong names are rejected and reported as a
   `policy_violation` surface failure. The final path must stay inside the
   safe destination; reparse points/symlinks on either end are rejected.
4. Bytes stream to a host-owned temporary file first. The commit uses
   `AtomicCommitDownload` (rename with create-new semantics) under a
   `ResolveNonOverwritingLeaf` name (`name (1).ext`), so an existing sibling
   is never silently overwritten.
5. Denial, timeout, navigation, close, host loss, or unavailable UI cancels
   the pending request terminally (`CancelPendingFileAccess`); a late
   approval cannot stage or commit bytes afterwards.

Private surfaces stage the same way; a user-approved download is a normal
user file and is not removed when the private context closes (see
`docs/cef-browser-runtime-profiles.md`).

## Clipboard

- Pages never receive a native clipboard handle. The host hands the page a
  mediated text snapshot for exactly one approved request id.
- Reads require a user gesture *and* an explicit one-shot app prompt
  (`AllowClipboardRead` / `decideClipboardRead`). The prompt is consumed by a
  single read. A read without a gesture is denied without emitting a prompt;
  an unaccepted prompt is denied.
- Writes require a user gesture *and* an admitted origin
  (`AllowClipboardWrite` / `decideClipboardWrite`): the origin must be one of
  the surface's declared `allowed_origins` / `allowed_loopback_origins`.
  There is no standing grant; every write is checked.
- The request carries the `write` and `user_gesture` bits so the app can
  render the correct one-shot prompt. Denial cancels terminally.

## Uploads

Uploads use the `upload_request` / `upload` command pair, which carries no
filesystem path:

1. A page file picker is intercepted in `OnFileDialog`. The default dialog
   is always canceled synchronously and exactly one `upload_request`
   (`multiple`, advisory `accept` filters) is emitted. Save dialogs are never
   admitted for uploads.
2. `AcceptUpload` means "show the OS/portal chooser". The host opens exactly
   one native chooser in `FILE_DIALOG_OPEN` mode; on Linux this goes through
   the desktop portal so the app never enumerates the filesystem itself.
3. The user's explicit selection is copied to host-owned read-only staging
   (`StagedUpload`). The page receives staged handles/bytes only: real paths
   are never sent to the page, no directory is enumerated, and no persistent
   path grant is kept. Staged copies are deleted after the handoff (or on any
   cancellation), so the grant expires with the request.
4. `DenyUpload` / `CancelUpload`, timeout, navigation, close, host loss, or
   unavailable UI cancels terminally; no chooser opens afterwards.

## Pending-request lifecycle

`PendingFileAccessRegistry` (Dart and Rust) tracks one entry per
`(surface, request_id)` with a 30-second one-shot budget
(`fileAccessRequestTimeoutMs` / `FILE_ACCESS_REQUEST_TIMEOUT_MS`):

- `cancelForNavigation` / `cancelForClose` drop that surface's requests.
- `cancelForHostLoss` drops everything when the host disappears.
- `expire` drops timed-out prompts.
- `cancelDenied` drops a denied request.
- `cancelForUnavailableUi` drops requests when no prompt/chooser can be
  shown (headless surface, missing window, destroyed view).
- `resolve` removes a request after the app produced a terminal decision.

Cancellation is idempotent: resolving an already-cancelled id returns false
and a cancelled id never resolves afterwards. The Windows host calls
`CancelPendingFileAccess` on navigation and close and
`CancelAllPendingFileAccess` on shutdown/host loss; the Linux `HostCore`
applies the same rule before dispatching navigation and close messages.
