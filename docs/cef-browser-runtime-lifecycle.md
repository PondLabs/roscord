# CEF BrowserRuntime lifecycle

`BrowserRuntime` keeps the four caller operations (`open`, `command`,
`events`, and `close`) small. Lifecycle diagnostics are additive: native
adapters expose a runtime-event stream containing a global `event_seq`, the
`runtime_epoch` of the host process, an optional redacted `failure_id`, and an
optional logical `surface_id`.

## States and failure boundary

The runtime state is one of `stopped`, `starting`, `ready`, `degraded`,
`restarting`, `failed`, or `stopping`. Host failures affect every logical
surface. Renderer and profile failures are surface-scoped; GPU failures put
the epoch into `degraded` and select the CPU renderer; utility failures are
reported for the affected request. The public classifications are stable and
do not expose CEF types:

- host: `host_start_failure`, `host_crash`, `host_unresponsive`,
  `host_protocol_violation`;
- renderer: crash, OOM, killed, abnormal exit, launch, integrity, and
  unresponsive;
- GPU: crash, launch failure, and `gpu_disabled`;
- utility: crash, network service failure, and launch failure;
- profile: locked, corrupt, and unavailable;
- lifecycle: `clean_stop` and `shutdown_timeout`.

Every failure record includes a generated diagnostic ID, scope, class,
recoverability, an optional raw termination status, and sanitized text. Paths,
URLs, cookies, tokens, profile keys, and page contents are not carried in the
record.
The Windows CEF client translates renderer termination and unresponsive
callbacks into the renderer classes; the host transport exposes the same
typed reporting seam for GPU, utility, and profile observations.

## Heartbeat and recovery policy

The adapter sends a host heartbeat every two seconds. Ten seconds without a
valid acknowledgement produces `host_unresponsive`; the old process gets a
five-second termination grace period before the next attempt. Automatic host
recovery is capped at three attempts in a rolling 60 seconds with delays of
250 ms, 1 s, and 4 s. A healthy epoch for 60 seconds clears that budget.

Bundle, signature, sandbox, protocol, profile-lock, and initialization
failures are terminal. After the budget is exhausted the runtime remains
`failed` until the user invokes **Retry browser**, which starts one fresh
epoch and one attempt. No recovery path starts WebView2, WebKitGTK/Wry, a
system CEF, or an unowned browser.

Logical surfaces retain their immutable `SurfaceSpec` and the latest
idempotent presentation values. Recovery emits `surface_recovering`, restores
surfaces in stable ID order, then emits `surface_restored` and the normal
`ready` event. Navigation history, page state, pending permissions/downloads,
and side effects are never recreated implicitly.

## Command outcomes

The host acknowledgement means only that a command was accepted for
execution. Every command carries a runtime-wide transport request ID in
addition to its per-surface sequence, so acknowledgements cannot be confused
when multiple surfaces use the same sequence number. If the host disappears before acknowledgement, the adapter emits
`command_outcome(failed, runtime_lost)`. An acknowledged command without a
terminal result emits `command_outcome(unknown, runtime_lost)`, because it may
already have taken effect. Navigation, script, input, popup, permission,
download, clipboard, capture, and other side-effecting commands are never
replayed. During recovery, only the latest resize/DPI, bounds, visibility, and
focus values may be held for the restored surface; a close always wins.

## Removed validation-only fault injection

The cutover deleted the positive-only `--cef-validation` switch and every
`--cef-fault=<point>` control from all builds. The Rust `cef_host`, the
Windows `cef_host`, and the Dart adapters reject those flags unconditionally;
there is no `FaultPoint` type, parser, build symbol, or user setting left.
Recovery is driven only by real host, renderer, GPU, utility, and profile
observations through `RuntimeLifecycle`. Forced software rendering
(`--cef-software-rendering`) is unaffected: it is a supported production
switch that keeps the CPU OnPaint contract, not a validation control.

The lifecycle tests exercise heartbeat timeout/backoff, host command outcome
classification, renderer/GPU scope, validation gating, and clean shutdown.
Child-scoped fault points are delivered through the authenticated host channel
as typed renderer, GPU, utility, or profile observations; host crash and
unresponsive points exercise transport recovery. Production argument parsing
rejects the controls before CEF initialization.
Platform smoke tests should additionally record the artifact/hash, locked CEF
version, compositor/presentation, ordered runtime events, command outcomes,
diagnostic ID, and an explicit no-dump result for clean shutdown.

## Clean shutdown

The adapter enters `stopping` before closing the transport, rejects new opens
and commands, cancels pending operations, closes surfaces, and joins the host.
`clean_stop` never increments crash counters or schedules recovery. A timeout
is recorded as `shutdown_timeout`; it does not show reconnect UI while the
application is exiting.
