import 'browser_runtime.dart';
import 'runtime_lifecycle.dart';

/// Consent-gated, rate-limited, redacted diagnostics for every surface.
///
/// Covers criterion 4 of #127 across Windows embedded/standalone, native
/// Linux embedded/standalone, Flatpak both presentations, and the Windows
/// official-video adapter: logs, metrics, dumps, and diagnostic IDs are
/// consent-gated, rate-limited, and redacted.
///
/// - Logs and metrics carry UTC time, runtime_epoch, host PID, optional
///   child PID/role, SurfaceId, presentation, platform/compositor, CEF
///   lock/version/hash, failure class/scope, raw status/exit code, command
///   sequence, and recovery time. Account/profile identifiers are hashed,
///   origins (not full URLs) are recorded, and cookies, tokens, page bodies,
///   script source, Matrix payloads, and paths are never logged.
/// - Production logging is warning/error with rotating 10 MiB x 5 install
///   logs and a 100 MiB crash spool.
/// - Low-cardinality consent-gated metrics cover runtime starts, host exits,
///   restart attempts, surface restores, renderer terminations, GPU/utility
///   events, command outcomes, shutdown results, downtime, runtime state,
///   and active surfaces.
/// - Crashpad/CEF minidumps cover host and every CEF child role with sidecars
///   (failure_id, role, PID, epoch, platform, lock/hash, symbol key). Upload
///   goes only through the existing consented crash-report path; otherwise a
///   local ID is retained and Copy diagnostic ID is offered. Capture and
///   upload are rate-limited.

/// Crash-report consent. Diagnostics never leave the device without it.
enum DiagnosticConsent { granted, denied }

/// Deterministic non-reversible hash for account/profile identifiers.
///
/// Uses FNV-1a 64-bit and renders as `profile-<16 hex>` so logs never carry
/// the raw stable local account-record identity.
///
/// In [BigInt]: on the web an `int` is a JavaScript number with 53 bits, and
/// the 64-bit literals this used to have stopped the whole web app from
/// compiling. The result is the one the native `int` version gave, a signed
/// 64-bit value, so identifiers already in logs keep matching.
String hashProfileKey(String profileKey) {
  var hash = _fnvOffset;
  for (final unit in profileKey.codeUnits) {
    hash ^= BigInt.from(unit);
    hash = (hash * _fnvPrime) & _mask64;
  }
  final signed = hash >= _signBit64 ? hash - _two64 : hash;
  return 'profile-${signed.toRadixString(16).padLeft(16, '0')}';
}

final _fnvOffset = BigInt.parse('cbf29ce484222325', radix: 16);
final _fnvPrime = BigInt.parse('100000001b3', radix: 16);
final _two64 = BigInt.one << 64;
final _signBit64 = BigInt.one << 63;
final _mask64 = _two64 - BigInt.one;

/// Records only the origin (scheme + host) of a URL, never the full URL,
/// path, query, or fragment. Controlled fixture URLs map to their origin;
/// unparseable values map to `<redacted-url>`.
String diagnosticOrigin(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
    return '<redacted-url>';
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http' && scheme != 'commet') {
    return '<redacted-url>';
  }
  return '$scheme://${uri.authority.toLowerCase()}';
}

/// Redacts a free-form diagnostic message using the same policy as
/// [sanitizeRuntimeMessage]: URLs, paths, and secrets never enter logs.
String redactDiagnosticMessage(String value) => sanitizeRuntimeMessage(value);

/// Opaque diagnostic identifier tied to one failure.
///
/// Stable format `d-<epoch>-<sequence>` so support can correlate a sanitized
/// log line, a metric, and a minidump sidecar without exposing cookies,
/// tokens, page bodies, or account identifiers.
class DiagnosticId {
  final int runtimeEpoch;
  final int sequence;

  const DiagnosticId(this.runtimeEpoch, this.sequence);

  @override
  String toString() => 'd-$runtimeEpoch-$sequence';

  @override
  bool operator ==(Object other) =>
      other is DiagnosticId &&
      other.runtimeEpoch == runtimeEpoch &&
      other.sequence == sequence;

  @override
  int get hashCode => Object.hash(runtimeEpoch, sequence);
}

/// Sanitized log record for one runtime event.
class DiagnosticLogRecord {
  final DateTime utcTime;
  final int runtimeEpoch;
  final int? hostPid;
  final int? childPid;
  final String? childRole;
  final SurfaceId? surfaceId;
  final String? presentation;
  final String? platformCompositor;
  final String? cefLock;
  final String? failureScope;
  final String? failureClass;
  final String? rawStatus;
  final int? commandSequence;
  final int? recoveryTimeMs;
  final String? profileHash;
  final String? origin;
  final String message;

  DiagnosticLogRecord({
    DateTime? utcTime,
    required this.runtimeEpoch,
    this.hostPid,
    this.childPid,
    this.childRole,
    this.surfaceId,
    this.presentation,
    this.platformCompositor,
    this.cefLock,
    this.failureScope,
    this.failureClass,
    this.rawStatus,
    this.commandSequence,
    this.recoveryTimeMs,
    String? profileKey,
    String? url,
    required String message,
  })  : utcTime = (utcTime ?? DateTime.now()).toUtc(),
        profileHash = profileKey == null ? null : hashProfileKey(profileKey),
        origin = url == null ? null : diagnosticOrigin(url),
        message = redactDiagnosticMessage(message);

  Map<String, Object?> toJson() => {
        'utc_time': utcTime.toIso8601String(),
        'runtime_epoch': runtimeEpoch,
        if (hostPid != null) 'host_pid': hostPid,
        if (childPid != null) 'child_pid': childPid,
        if (childRole != null) 'child_role': childRole,
        if (surfaceId != null) 'surface_id': surfaceId!.value,
        if (presentation != null) 'presentation': presentation,
        if (platformCompositor != null)
          'platform_compositor': platformCompositor,
        if (cefLock != null) 'cef_lock': cefLock,
        if (failureScope != null) 'failure_scope': failureScope,
        if (failureClass != null) 'failure_class': failureClass,
        if (rawStatus != null) 'raw_status': rawStatus,
        if (commandSequence != null) 'command_sequence': commandSequence,
        if (recoveryTimeMs != null) 'recovery_time_ms': recoveryTimeMs,
        if (profileHash != null) 'profile_hash': profileHash,
        if (origin != null) 'origin': origin,
        'message': message,
      };
}

/// Low-cardinality metric name allow-list for consent-gated reporting.
const Set<String> diagnosticMetricNames = {
  'runtime_starts',
  'host_exits',
  'restart_attempts',
  'surface_restores',
  'renderer_terminations',
  'gpu_events',
  'utility_events',
  'command_outcomes',
  'shutdown_results',
  'downtime_ms',
  'runtime_state',
  'active_surfaces',
};

/// Rate-limited, consent-gated diagnostic sink.
///
/// - Capture is bounded: at most [maxCapturesPerMinute] records are kept;
///   the rest are dropped and counted as `dropped_captures`.
/// - Upload is bounded: at most [maxUploadsPerHour] uploads are attempted;
///   otherwise the record stays local and only its [DiagnosticId] is shown
///   with a Copy diagnostic ID action.
/// - Without consent, nothing is uploaded: [tryUpload] always returns false
///   and callers retain the local ID.
/// - Disk budgets mirror the host contract: 10 MiB x 5 rotating install logs
///   and a 100 MiB crash spool. [wouldExceedDiskBudget] guards before write.
class RateLimitedDiagnosticStore {
  final int maxCapturesPerMinute;
  final int maxUploadsPerHour;
  final int maxDiskBytes;

  final List<int> _captureTimes = [];
  final List<int> _uploadTimes = [];
  int droppedCaptures = 0;
  int droppedUploads = 0;
  int _nextSequence = 1;

  RateLimitedDiagnosticStore({
    this.maxCapturesPerMinute = 30,
    this.maxUploadsPerHour = 10,
    this.maxDiskBytes = 100 * 1024 * 1024,
  });

  DiagnosticId nextId(int runtimeEpoch) =>
      DiagnosticId(runtimeEpoch, _nextSequence++);

  bool _prune(List<int> times, int nowMs, int windowMs) {
    times.removeWhere((time) => nowMs - time >= windowMs);
    return true;
  }

  /// Attempts to capture one record. Returns the ID when kept, null when
  /// rate-limited (counted in [droppedCaptures]).
  DiagnosticId? tryCapture(int nowMs, int runtimeEpoch) {
    _prune(_captureTimes, nowMs, 60000);
    if (_captureTimes.length >= maxCapturesPerMinute) {
      droppedCaptures++;
      return null;
    }
    _captureTimes.add(nowMs);
    return nextId(runtimeEpoch);
  }

  /// Attempts one upload through the consented crash-report path. Returns
  /// true only when [consent] is granted and the hourly budget allows it.
  /// Denied consent or budget exhaustion returns false and counts a dropped
  /// upload without transmitting anything.
  bool tryUpload(int nowMs, DiagnosticConsent consent) {
    if (consent != DiagnosticConsent.granted) return false;
    _prune(_uploadTimes, nowMs, 3600000);
    if (_uploadTimes.length >= maxUploadsPerHour) {
      droppedUploads++;
      return false;
    }
    _uploadTimes.add(nowMs);
    return true;
  }

  bool wouldExceedDiskBudget(int currentBytes, int incomingBytes) =>
      currentBytes + incomingBytes > maxDiskBytes;

  /// Copy diagnostic ID offered when upload is unavailable: the local ID is
  /// retained and the user can paste it into a support report.
  String copyDiagnosticId(DiagnosticId id) => id.toString();
}
