# CEF BrowserRuntime navigation and popup policy

Every desktop CEF surface carries an immutable navigation policy. The policy
is checked in Dart/Rust before it reaches the host and checked again by the
native callbacks. A failed check cancels the browser operation and emits a
normalized `navigation` event; no callback opens a fallback engine or an
unowned native window.

## In-CEF destinations

The `allowed_origins` list may contain exact `https://` origins and controlled
`commet://` origins. The `allowed_loopback_origins` list is separate and only
accepts exact `http://localhost`, `http://127.0.0.1`, or `http://[::1]` origins
with an explicit port. Paths, credentials, fragments, arbitrary custom
schemes, `file:`, `javascript:`, `data:`, `chrome:`, `devtools:`, and
`view-source:` are rejected. The host-owned `commet://fixture/` bootstrap is
the one built-in controlled destination used by validation fixtures.

Redirects and top-level navigations pass through the same origin check. A
declared destination produces a normalized `navigation` event with
`outcome=allowed`. An undeclared automatic navigation is canceled. A
user-initiated request for an undeclared destination, including an explicit
external request, is allowed only when the caller set
`allow_external_navigation`; it is reported as `disposition=external`,
`outcome=external` for the app to route through its normal external-link, SSO,
or remote-device action.

## TLS and client certificates

CEF uses normal Chromium/system trust validation. Certificate errors call
`Cancel`, emit a surface-scoped canceled navigation, and emit a sanitized
`certificate_denied` failure; client-certificate selection always calls
`Select(nullptr)` and emits a surface-scoped `client_certificate_denied`
failure. The runtime never enables
`ignore_certificate_errors`, remembers certificate exceptions, or accepts a
certificate merely because the page is in a widget surface.

## Popups and new windows

`OnBeforePopup` cancels creation synchronously and emits a `popup_request`
event containing the URL and user-gesture bit. The app may deny it or approve
an explicit external action with the same account/privacy policy. The host
does not create a default CEF popup, top-level HWND, or unowned browser. A
non-gesture popup, an unknown request, and the reserved owned-popup action are
all canceled.

## Policy ownership

`SurfacePolicy` is serialized in the versioned BrowserRuntime protocol, and
the Rust Linux host applies the same decision table as the Windows callbacks.
Policy data contains origins and generic routing flags only; Matrix capability
names and widget protocol messages remain in the Dart adapter.
