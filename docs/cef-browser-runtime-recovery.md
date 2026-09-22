# Recovery, diagnostics, and observability across all surfaces (#127)

Fan-in of #121 (Windows embedded), #122 (Windows standalone), #123 (native
Linux embedded), #124 (native Linux standalone), #125 (Flatpak both
presentations), and #126 (Windows official video through MediaEmbedAdapter).

## Host restart

`SurfaceRecoveryCoordinator` (`commet/lib/browser_runtime/surface_recovery.dart`)
wraps `RuntimeLifecycle` and owns the declarative registry shared by every
presenter. A host restart recreates contexts and surfaces in stable
`SurfaceId` order from the immutable `SurfaceSpec` plus the latest idempotent
presentation values (resize/DPI, bounds, visibility, focus). History,
undeclared current URL, unsaved page state, pending permissions, pending
downloads, clipboard, and capture handles are never stored and never replayed.

`isSideEffectingCommand` classifies navigation, script, input, popup/window
actions, permission decisions, downloads, clipboard, and uploads as
side-effecting; `shouldReplayCommand` is always false. An unacknowledged
command at host loss completes as failed; an acknowledged command without a
terminal outcome becomes unknown. During restart only the latest
resize/DPI/bounds/visibility/focus values are held (`heldResizes`,
`heldFocus`). A close always wins, including after `noteHostLost`.

## Renderer, GPU, retry budgets

Renderer recovery is surface-scoped through `RuntimeLifecycle`: at most two
recoveries per surface in a rolling 60 seconds, a 5-second app grace after
CEF reports unresponsive, then terminal `surface_failed` until explicit
Retry. GPU child failure records `gpu_degraded` and uses CPU software
rendering; two GPU failures in 60 seconds pin the epoch to `gpu_disabled`.
Host restarts use 250 ms, 1 s, and 4 s delays with at most three automatic
restarts in a rolling 60 seconds; deterministic bundle/hash/signature/
sandbox/protocol/initialization failures are terminal. A manual Retry
starts one fresh epoch and one attempt.

## Accessible recovery UI

`recovery_surface_ui.dart` provides the shared widgets used by every
presentation and by the official-video dialog chrome:

- `ReconnectingBrowserOverlay` ("Reconnecting browser…") as a live region.
- `CrashedSurfaceCard` ("This embedded page crashed. Retry" or "Graphics
  unavailable. Retry") with Retry, Close, Report diagnostics, and Copy
  diagnostic ID.
- `RuntimeUnavailableCard` ("Embedded browser unavailable. Retry browser").

Raw process paths, URLs, CEF statuses, profile IDs, cookies, and device IDs
are never shown; only the fixed strings plus an opaque diagnostic ID (for
example `d-3-7`) are rendered. Every control is keyboard-focusable, exposes
a semantic label and hint, honors text scaling, and never signals by color
alone.

## Diagnostics and observability

`surface_diagnostics.dart` implements the consent-gated, rate-limited,
redacted sink:

- `DiagnosticLogRecord` carries UTC time, runtime epoch, host/child PIDs and
  role, SurfaceId, presentation, platform/compositor, CEF lock, failure
  class/scope, raw status/exit code, command sequence, and recovery time.
  Profiles hash via `hashProfileKey`, URLs reduce to origins via
  `diagnosticOrigin`, and messages redact via `sanitizeRuntimeMessage`.
- `RateLimitedDiagnosticStore` bounds capture (30/min), upload (10/hour),
  and disk (100 MiB crash spool; 10 MiB x 5 install logs). Upload goes only
  through the consented crash-report path; otherwise the local ID is retained
  and Copy diagnostic ID is offered.
- Metric names stay low-cardinality (`diagnosticMetricNames`).

## Clean close

`shutdownDrainOrder` closes all surfaces and owned windows in stable
`SurfaceId` order, drains callbacks and profile flush for up to 5 seconds,
then `CefShutdown` joins the host within 10 seconds. A timeout records
`shutdown_timeout` but never schedules recovery during app exit; clean stop
never increments crash counters. Every presenter (`noteHostLost` /
`isReconnecting` / `noteRestored` / `close`) follows the same close-wins
contract so no orphan surface, window, or host process survives.
