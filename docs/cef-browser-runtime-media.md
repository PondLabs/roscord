# CEF BrowserRuntime media and capture permissions

Camera, microphone, and screen-capture access is deny-by-default and fails
closed through OS/portal mediation.  The decision table below is implemented
three times against the same contract: the Dart `media_permission.dart`
library (fixtures and adapter tests), the Rust `browser_media` module (used
directly by the Linux host), and the Windows host controller next to its CEF
permission callbacks.

## Capabilities

A permission request carries one canonical capability wire name:

- `camera`, `microphone`, `camera+microphone` — device capture
  (`getUserMedia`).
- `display_video`, `display_audio`, `display_video+display_audio` — screen or
  window capture (`getDisplayMedia`).
- Anything else classifies as unknown and is always denied.  Unknown
  capabilities are never grantable and never inherit a grant.

Matching is exact and case-sensitive, so a near-miss capability cannot
inherit a grant.

## Decisions and grant scopes

Camera/microphone decisions support deny, once, session, and explicitly
scoped persistent grants (`deny`, `allow_once`, `allow_session`,
`allow_always` on the wire).  Every stored grant is keyed by all four of:

- the account profile key,
- the requesting origin,
- the top-level origin,
- the capability.

A grant never crosses any of these boundaries.  An explicit deny revokes the
stored grant for its scope; `allow_once` applies to the pending request only
and stores nothing.

Every use of a stored grant re-checks the surface's current policy (both
origins must still be declared and the capability must not be explicitly
disabled) and the OS-level mediation check.  A grant whose origins left the
policy simply does not apply.

## Display capture always needs fresh consent

Display capture never receives a persistent grant.  Every display-capture
request emits a fresh `permission_request` event and waits for an explicit
app decision; `allow_always` on a display request degrades to once (the
pending request may proceed, nothing is stored).  A stored grant of any kind
never satisfies a display request.

Private surfaces never hold persistent grants either: `allow_always` there
is kept as a memory-only session grant, and persistent grants stored outside
private mode are not honored for private use.  Session grants evaporate on
host restart and recovery; every grant for an account is dropped by
clear-data.

## Platform mediation paths

- Windows uses the qualified OS path: every request arrives at
  `OnRequestMediaAccessPermission`, the host returns true (handled) and
  either continues a covered grant or stashes the callback and emits
  `permission_request` for the app.  The actual capture stays inside
  Chromium's OS-mediated device and screen-capture stack; the host never
  calls Win32 capture APIs directly and rejects media-bypass switches
  (`--enable-media-stream`, `--use-fake-device-for-media-stream`,
  `--use-fake-ui-for-media-stream`).
- Linux and Flatpak use the qualified XDG ScreenCast/PipeWire portal path:
  every display request goes through the portal dialog first, and only a
  portal grant plus fresh app consent continues the page request.  There is
  no direct X11 fallback: the host contains no `XGetImage`, MIT-SHM, or
  compositor screenshot path.
- Generic permission prompts (geolocation and similar) are always denied;
  there is no grant store for them and no bypass.

## Portal and denial outcomes

Portal denial, dismissal, timeout, disconnect, and unsupported capability
all deliver a normal page denial (the CEF callback is canceled) plus a
sanitized `capture_denied` failure event.  App-driven and policy denials
deliver a normal page denial plus a sanitized `permission_denied` failure.
Failure text is fixed per outcome and never carries origins, paths, tokens,
or page contents.

Decisions for requests the host never issued are rejected with
`unknown_permission_request` without granting anything, and pending
requests are dropped when their surface closes so a late decision can never
grant a dead surface.
