import 'browser_runtime.dart';

const heartbeatIntervalMs = 2000;
const heartbeatTimeoutMs = 10000;
const hostTerminationGraceMs = 5000;
const restartWindowMs = 60000;
const healthyResetMs = 60000;
const maxAutomaticHostRestarts = 3;
const maxRendererRecoveries = 2;
const maxGpuFailures = 2;

const _automaticRestartDelaysMs = <int>[250, 1000, 4000];

enum RuntimeState {
  stopped,
  starting,
  ready,
  degraded,
  restarting,
  failed,
  stopping,
}

enum FailureScope { lifecycle, host, renderer, gpu, utility, profile }

enum FailureClass {
  cleanStop,
  shutdownTimeout,
  hostStartFailure,
  hostCrash,
  hostUnresponsive,
  hostProtocolViolation,
  rendererCrash,
  rendererOom,
  rendererKilled,
  rendererAbnormalExit,
  rendererLaunchFailed,
  rendererIntegrityFailure,
  rendererUnresponsive,
  gpuCrash,
  gpuLaunchFailed,
  gpuDisabled,
  utilityCrash,
  networkServiceFailure,
  utilityLaunchFailed,
  profileLocked,
  profileCorrupt,
  profileUnavailable,
  graphicsUnavailable,
}

extension FailureClassMetadata on FailureClass {
  FailureScope get scope => switch (this) {
        FailureClass.cleanStop ||
        FailureClass.shutdownTimeout =>
          FailureScope.lifecycle,
        FailureClass.hostStartFailure ||
        FailureClass.hostCrash ||
        FailureClass.hostUnresponsive ||
        FailureClass.hostProtocolViolation =>
          FailureScope.host,
        FailureClass.rendererCrash ||
        FailureClass.rendererOom ||
        FailureClass.rendererKilled ||
        FailureClass.rendererAbnormalExit ||
        FailureClass.rendererLaunchFailed ||
        FailureClass.rendererIntegrityFailure ||
        FailureClass.rendererUnresponsive ||
        FailureClass.graphicsUnavailable =>
          FailureScope.renderer,
        FailureClass.gpuCrash ||
        FailureClass.gpuLaunchFailed ||
        FailureClass.gpuDisabled =>
          FailureScope.gpu,
        FailureClass.utilityCrash ||
        FailureClass.networkServiceFailure ||
        FailureClass.utilityLaunchFailed =>
          FailureScope.utility,
        FailureClass.profileLocked ||
        FailureClass.profileCorrupt ||
        FailureClass.profileUnavailable =>
          FailureScope.profile,
      };

  bool get deterministic => switch (this) {
        FailureClass.hostStartFailure ||
        FailureClass.hostProtocolViolation ||
        FailureClass.profileLocked ||
        FailureClass.profileCorrupt =>
          true,
        _ => false,
      };

  bool get cleanStop => this == FailureClass.cleanStop;
}

class RuntimeFailure {
  final String failureId;
  final FailureScope scope;
  final FailureClass kind;
  final bool recoverable;
  final String? rawStatus;
  final String message;

  RuntimeFailure({
    required this.failureId,
    required this.kind,
    String? rawStatus,
    required String message,
  })  : scope = kind.scope,
        recoverable = !kind.deterministic && !kind.cleanStop,
        message = _sanitize(message, 512),
        rawStatus = rawStatus == null ? null : _sanitize(rawStatus, 128);

  Map<String, Object?> toJson() => {
        'failure_id': failureId,
        'scope': _wireName(scope.name),
        'class': _wireName(kind.name),
        'recoverable': recoverable,
        if (rawStatus != null) 'raw_status': rawStatus,
        'message': message,
      };
}

enum RuntimeEventType {
  stateChanged,
  heartbeatSent,
  heartbeatAck,
  failure,
  restartScheduled,
  commandOutcome,
  surfaceRecovering,
  surfaceRestored,
  surfaceFailed,
  shutdownComplete,
}

class RuntimeEventKind {
  final RuntimeEventType type;
  final RuntimeState? state;
  final int? requestId;
  final RuntimeFailure? failure;
  final int? attempt;
  final int? delayMs;
  final int? commandId;
  final CommandOutcome? outcome;
  final CommandOutcomeReason? reason;
  final bool? clean;

  const RuntimeEventKind._(
    this.type, {
    this.state,
    this.requestId,
    this.failure,
    this.attempt,
    this.delayMs,
    this.commandId,
    this.outcome,
    this.reason,
    this.clean,
  });

  const RuntimeEventKind.stateChanged(RuntimeState state)
      : this._(RuntimeEventType.stateChanged, state: state);

  const RuntimeEventKind.heartbeatSent(int requestId)
      : this._(RuntimeEventType.heartbeatSent, requestId: requestId);

  const RuntimeEventKind.heartbeatAck(int requestId)
      : this._(RuntimeEventType.heartbeatAck, requestId: requestId);

  const RuntimeEventKind.failure(RuntimeFailure failure)
      : this._(RuntimeEventType.failure, failure: failure);

  const RuntimeEventKind.restartScheduled(int attempt, int delayMs)
      : this._(
          RuntimeEventType.restartScheduled,
          attempt: attempt,
          delayMs: delayMs,
        );

  const RuntimeEventKind.commandOutcome(
    int commandId,
    CommandOutcome outcome,
    CommandOutcomeReason reason,
  ) : this._(
          RuntimeEventType.commandOutcome,
          commandId: commandId,
          outcome: outcome,
          reason: reason,
        );

  const RuntimeEventKind.surfaceRecovering()
      : this._(RuntimeEventType.surfaceRecovering);

  const RuntimeEventKind.surfaceRestored()
      : this._(RuntimeEventType.surfaceRestored);

  const RuntimeEventKind.surfaceFailed(RuntimeFailure failure)
      : this._(RuntimeEventType.surfaceFailed, failure: failure);

  const RuntimeEventKind.shutdownComplete(bool clean)
      : this._(RuntimeEventType.shutdownComplete, clean: clean);
}

class RuntimeEvent {
  final int eventSeq;
  final int runtimeEpoch;
  final String? failureId;
  final SurfaceId? surfaceId;
  final RuntimeEventKind kind;

  const RuntimeEvent({
    required this.eventSeq,
    required this.runtimeEpoch,
    required this.kind,
    this.failureId,
    this.surfaceId,
  });

  Map<String, Object?> toJson() => {
        'event_seq': eventSeq,
        'runtime_epoch': runtimeEpoch,
        if (failureId != null) 'failure_id': failureId,
        if (surfaceId != null) 'surface_id': surfaceId!.value,
        'kind': _wireName(kind.type.name),
        if (kind.state != null) 'state': _wireName(kind.state!.name),
        if (kind.requestId != null) 'request_id': kind.requestId,
        if (kind.failure != null) 'failure': kind.failure!.toJson(),
        if (kind.attempt != null) 'attempt': kind.attempt,
        if (kind.delayMs != null) 'delay_ms': kind.delayMs,
        if (kind.commandId != null) 'command_id': kind.commandId,
        if (kind.outcome != null) 'outcome': _wireName(kind.outcome!.name),
        if (kind.reason != null) 'reason': _wireName(kind.reason!.name),
        if (kind.clean != null) 'clean': kind.clean,
      };
}

class CommandToken {
  final int commandId;
  final SurfaceId surfaceId;
  final bool sideEffecting;

  const CommandToken(this.commandId, this.surfaceId, this.sideEffecting);
}

enum CommandOutcome { failed, unknown }

enum CommandOutcomeReason { runtimeLost }

class RuntimeLifecycleException implements Exception {
  final RuntimeState state;
  final String action;

  const RuntimeLifecycleException(this.state, this.action);

  @override
  String toString() => 'RuntimeLifecycleException($state): $action';
}

/// Additive diagnostics for implementations that do not own a platform
/// lifecycle controller.  Native adapters override this with a broadcast
/// stream; the original four-operation interface remains source-compatible.
extension BrowserRuntimeDiagnostics on BrowserRuntime {
  Stream<RuntimeEvent> runtimeEvents() => const Stream<RuntimeEvent>.empty();
}

class _SurfaceRecord {
  final SurfaceSpec spec;
  final List<int> rendererFailures = [];
  final Map<String, String> presentation = {};

  _SurfaceRecord(this.spec);
}

class _CommandRecord {
  final CommandToken token;
  bool acknowledged = false;

  _CommandRecord(this.token);
}

/// Pure policy engine used by both platform adapters and deterministic tests.
class RuntimeLifecycle {
  RuntimeState state = RuntimeState.stopped;
  int runtimeEpoch = 0;
  int _nextEventSeq = 1;
  int _nextFailureSeq = 1;
  int _nextHeartbeatId = 1;
  int _nextCommandId = 1;
  int? _lastHeartbeatSentMs;
  int? _lastHeartbeatAckMs;
  int? _pendingHeartbeat;
  int? restartDueMs;
  final List<int> _restartAttempts = [];
  final List<int> _gpuFailures = [];
  int? _healthySinceMs;
  bool _gpuDisabled = false;
  bool _stoppingIntentionally = false;
  final Map<SurfaceId, _SurfaceRecord> _surfaces = {};
  final Map<int, _CommandRecord> _commands = {};

  int automaticRestartAttempts(int nowMs) =>
      _restartAttempts.where((time) => nowMs - time < restartWindowMs).length;

  Iterable<SurfaceId> get surfaceIds => _surfaces.keys;

  /// Whether this runtime epoch has been pinned to software rendering after
  /// repeated GPU failures.
  bool get gpuDisabled => _gpuDisabled;

  void registerSurface(SurfaceId surfaceId, SurfaceSpec spec) {
    _surfaces.putIfAbsent(surfaceId, () => _SurfaceRecord(spec));
  }

  SurfaceSpec? surfaceSpec(SurfaceId surfaceId) => _surfaces[surfaceId]?.spec;

  void removeSurface(SurfaceId surfaceId) {
    if (_surfaces.remove(surfaceId) == null) {
      throw StateError('unknown surface $surfaceId');
    }
  }

  void setPresentationValue(SurfaceId surfaceId, String key, String value) {
    final surface = _surfaces[surfaceId];
    if (surface == null) throw StateError('unknown surface $surfaceId');
    surface.presentation[key] = value;
  }

  String? presentationValue(SurfaceId surfaceId, String key) =>
      _surfaces[surfaceId]?.presentation[key];

  List<RuntimeEvent> start(int nowMs) {
    if (!{
      RuntimeState.stopped,
      RuntimeState.restarting,
      RuntimeState.failed,
    }.contains(state)) {
      throw RuntimeLifecycleException(state, 'start');
    }
    _stoppingIntentionally = false;
    runtimeEpoch++;
    _pendingHeartbeat = null;
    _lastHeartbeatSentMs = null;
    _lastHeartbeatAckMs = nowMs;
    _healthySinceMs = null;
    _gpuFailures.clear();
    _gpuDisabled = false;
    for (final surface in _surfaces.values) {
      surface.rendererFailures.clear();
    }
    restartDueMs = null;
    final events = <RuntimeEvent>[
      RuntimeEvent(
        eventSeq: 0,
        runtimeEpoch: 0,
        kind: const RuntimeEventKind.stateChanged(RuntimeState.starting),
      ),
    ];
    events[0] = _stateEvent(RuntimeState.starting);
    for (final surfaceId in surfaceIds.toList()) {
      events.add(
        _surfaceEvent(surfaceId, const RuntimeEventKind.surfaceRecovering()),
      );
    }
    state = RuntimeState.starting;
    return events;
  }

  List<RuntimeEvent> hostReady(int nowMs) {
    if (state != RuntimeState.starting && state != RuntimeState.degraded) {
      throw RuntimeLifecycleException(state, 'hostReady');
    }
    _lastHeartbeatAckMs = nowMs;
    _healthySinceMs = nowMs;
    _pendingHeartbeat = null;
    final events = <RuntimeEvent>[_stateEvent(RuntimeState.ready)];
    for (final surfaceId in surfaceIds.toList()) {
      events.add(
        _surfaceEvent(surfaceId, const RuntimeEventKind.surfaceRestored()),
      );
    }
    state = RuntimeState.ready;
    return events;
  }

  RuntimeEvent? heartbeatDue(int nowMs) {
    if (state != RuntimeState.ready && state != RuntimeState.degraded)
      return null;
    if ((_lastHeartbeatSentMs != null &&
            nowMs - _lastHeartbeatSentMs! < heartbeatIntervalMs) ||
        _pendingHeartbeat != null) {
      return null;
    }
    final requestId = _nextHeartbeatId++;
    _lastHeartbeatSentMs = nowMs;
    _pendingHeartbeat = requestId;
    return _event(RuntimeEventKind.heartbeatSent(requestId));
  }

  RuntimeEvent heartbeatAck(int requestId, int nowMs) {
    if (_pendingHeartbeat != requestId) {
      throw RuntimeLifecycleException(state, 'heartbeatAck');
    }
    _pendingHeartbeat = null;
    _lastHeartbeatAckMs = nowMs;
    _healthySinceMs ??= nowMs;
    return _event(RuntimeEventKind.heartbeatAck(requestId));
  }

  List<RuntimeEvent> tick(int nowMs) {
    final events = <RuntimeEvent>[];
    if (_healthySinceMs != null && nowMs - _healthySinceMs! >= healthyResetMs) {
      _restartAttempts.clear();
      _healthySinceMs = nowMs;
    }
    if (_lastHeartbeatAckMs != null &&
        (state == RuntimeState.ready || state == RuntimeState.degraded) &&
        nowMs - _lastHeartbeatAckMs! >= heartbeatTimeoutMs) {
      events.addAll(
        reportFailure(
          FailureClass.hostUnresponsive,
          nowMs,
          message: 'host heartbeat timed out',
        ),
      );
      events.addAll(_resolveCommands(FailureClass.hostUnresponsive));
    }
    final heartbeat = heartbeatDue(nowMs);
    if (heartbeat != null) events.add(heartbeat);
    return events;
  }

  List<RuntimeEvent> reportFailure(
    FailureClass kind,
    int nowMs, {
    String? rawStatus,
    required String message,
  }) =>
      _reportFailure(
        kind,
        nowMs,
        rawStatus: rawStatus,
        message: message,
      );

  List<RuntimeEvent> reportSurfaceFailure(
    SurfaceId surfaceId,
    FailureClass kind,
    int nowMs, {
    String? rawStatus,
    required String message,
  }) {
    if (!_surfaces.containsKey(surfaceId)) {
      throw StateError('unknown surface $surfaceId');
    }
    return _reportFailure(
      kind,
      nowMs,
      rawStatus: rawStatus,
      message: message,
      targetSurfaceId: surfaceId,
    );
  }

  List<RuntimeEvent> _reportFailure(
    FailureClass kind,
    int nowMs, {
    String? rawStatus,
    required String message,
    SurfaceId? targetSurfaceId,
  }) {
    final classification =
        _stoppingIntentionally && kind.scope == FailureScope.host
            ? FailureClass.cleanStop
            : kind;
    final failureId = 'f-$runtimeEpoch-${_nextFailureSeq++}';
    final failure = RuntimeFailure(
      failureId: failureId,
      kind: classification,
      rawStatus: rawStatus,
      message: message,
    );
    final events = <RuntimeEvent>[
      _event(RuntimeEventKind.failure(failure), failureId: failureId),
    ];
    if (classification.cleanStop || _stoppingIntentionally) return events;
    switch (classification.scope) {
      case FailureScope.host:
        if (classification.deterministic) {
          events.add(
            _stateEvent(RuntimeState.failed, failureId: failureId),
          );
          state = RuntimeState.failed;
        } else {
          events.addAll(_scheduleHostRestart(failureId, nowMs));
        }
      case FailureScope.renderer:
        final surfaceId = targetSurfaceId ?? surfaceIds.firstOrNull;
        if (surfaceId != null) {
          final attempts = _surfaces[surfaceId]!.rendererFailures;
          _prune(attempts, nowMs);
          attempts.add(nowMs);
          if (attempts.length <= maxRendererRecoveries) {
            events.add(
              _surfaceEvent(
                surfaceId,
                const RuntimeEventKind.surfaceRecovering(),
                failureId: failureId,
              ),
            );
          } else {
            events.add(
              _event(
                RuntimeEventKind.surfaceFailed(failure),
                failureId: failureId,
                surfaceId: surfaceId,
              ),
            );
          }
        }
      case FailureScope.gpu:
        _prune(_gpuFailures, nowMs);
        _gpuFailures.add(nowMs);
        if (state != RuntimeState.degraded) {
          events.add(
            _stateEvent(RuntimeState.degraded, failureId: failureId),
          );
          state = RuntimeState.degraded;
        }
        if (_gpuFailures.length >= maxGpuFailures && !_gpuDisabled) {
          _gpuDisabled = true;
          final disabledFailureId = 'f-$runtimeEpoch-${_nextFailureSeq++}';
          final disabledFailure = RuntimeFailure(
            failureId: disabledFailureId,
            kind: FailureClass.gpuDisabled,
            rawStatus: kind.name,
            message: 'software rendering pinned after repeated GPU failures',
          );
          events.add(
            _event(
              RuntimeEventKind.failure(disabledFailure),
              failureId: disabledFailureId,
            ),
          );
        }
      case FailureScope.profile:
        final surfaceId = targetSurfaceId ?? surfaceIds.firstOrNull;
        if (surfaceId != null) {
          events.add(
            _event(
              RuntimeEventKind.surfaceFailed(failure),
              failureId: failureId,
              surfaceId: surfaceId,
            ),
          );
        } else if (classification.deterministic) {
          events.add(
            _stateEvent(RuntimeState.failed, failureId: failureId),
          );
          state = RuntimeState.failed;
        }
      case FailureScope.utility || FailureScope.lifecycle:
        break;
    }
    return events;
  }

  List<RuntimeEvent> hostLost(
    int nowMs, {
    String message = 'host exited',
    String? rawStatus,
  }) {
    if (_stoppingIntentionally ||
        state == RuntimeState.stopping ||
        state == RuntimeState.stopped) {
      return reportFailure(
        FailureClass.cleanStop,
        nowMs,
        rawStatus: rawStatus,
        message: message,
      );
    }
    return [
      ...reportFailure(
        FailureClass.hostCrash,
        nowMs,
        rawStatus: rawStatus,
        message: message,
      ),
      ..._resolveCommands(FailureClass.hostCrash),
    ];
  }

  List<RuntimeEvent> hostProtocolViolation(
    int nowMs, {
    required String message,
  }) {
    return [
      ...reportFailure(
        FailureClass.hostProtocolViolation,
        nowMs,
        message: message,
      ),
      ..._resolveCommands(FailureClass.hostProtocolViolation),
    ];
  }

  List<RuntimeEvent> retry(int nowMs) {
    if (state != RuntimeState.failed) {
      throw RuntimeLifecycleException(state, 'retry');
    }
    _restartAttempts.clear();
    return start(nowMs);
  }

  bool get restartReady =>
      state == RuntimeState.restarting && restartDueMs != null;

  CommandToken beginCommand(
    SurfaceId surfaceId, {
    required bool sideEffecting,
  }) {
    if (state != RuntimeState.ready && state != RuntimeState.degraded) {
      throw RuntimeLifecycleException(state, 'command');
    }
    if (!_surfaces.containsKey(surfaceId)) {
      throw StateError('unknown surface $surfaceId');
    }
    final token = CommandToken(_nextCommandId++, surfaceId, sideEffecting);
    _commands[token.commandId] = _CommandRecord(token);
    return token;
  }

  void acknowledgeCommand(int commandId) {
    final command = _commands[commandId];
    if (command == null) throw StateError('unknown command $commandId');
    command.acknowledged = true;
  }

  void completeCommand(int commandId) {
    if (_commands.remove(commandId) == null) {
      throw StateError('unknown command $commandId');
    }
  }

  bool shouldReplayCommand(int commandId) => false;

  List<RuntimeEvent> beginShutdown() {
    _stoppingIntentionally = true;
    if (state == RuntimeState.stopping || state == RuntimeState.stopped) {
      return const [];
    }
    state = RuntimeState.stopping;
    return [_stateEvent(RuntimeState.stopping)];
  }

  List<RuntimeEvent> finishShutdown({required bool clean}) {
    _pendingHeartbeat = null;
    restartDueMs = null;
    _commands.clear();
    state = RuntimeState.stopped;
    return [_event(RuntimeEventKind.shutdownComplete(clean))];
  }

  List<RuntimeEvent> _resolveCommands(FailureClass _reason) {
    final pending = _commands.values.toList()
      ..sort((a, b) => a.token.commandId.compareTo(b.token.commandId));
    _commands.clear();
    return pending.map((command) {
      final outcome =
          command.acknowledged ? CommandOutcome.unknown : CommandOutcome.failed;
      return _event(
        RuntimeEventKind.commandOutcome(
          command.token.commandId,
          outcome,
          CommandOutcomeReason.runtimeLost,
        ),
        surfaceId: command.token.surfaceId,
      );
    }).toList();
  }

  List<RuntimeEvent> _scheduleHostRestart(String failureId, int nowMs) {
    _prune(_restartAttempts, nowMs);
    final attempt = _restartAttempts.length;
    if (attempt >= maxAutomaticHostRestarts) {
      state = RuntimeState.failed;
      return [_stateEvent(RuntimeState.failed, failureId: failureId)];
    }
    final delayMs = _automaticRestartDelaysMs[attempt];
    _restartAttempts.add(nowMs);
    restartDueMs = nowMs + hostTerminationGraceMs + delayMs;
    final events = <RuntimeEvent>[];
    if (state != RuntimeState.restarting) {
      state = RuntimeState.restarting;
      events.add(
        _stateEvent(RuntimeState.restarting, failureId: failureId),
      );
      for (final surfaceId in surfaceIds.toList()) {
        events.add(
          _surfaceEvent(
            surfaceId,
            const RuntimeEventKind.surfaceRecovering(),
            failureId: failureId,
          ),
        );
      }
    }
    events.add(
      _event(
        RuntimeEventKind.restartScheduled(attempt + 1, delayMs),
        failureId: failureId,
      ),
    );
    return events;
  }

  RuntimeEvent _stateEvent(RuntimeState next, {String? failureId}) =>
      _event(RuntimeEventKind.stateChanged(next), failureId: failureId);

  RuntimeEvent _surfaceEvent(
    SurfaceId surfaceId,
    RuntimeEventKind kind, {
    String? failureId,
  }) =>
      _event(kind, failureId: failureId, surfaceId: surfaceId);

  RuntimeEvent _event(
    RuntimeEventKind kind, {
    String? failureId,
    SurfaceId? surfaceId,
  }) {
    return RuntimeEvent(
      eventSeq: _nextEventSeq++,
      runtimeEpoch: runtimeEpoch,
      failureId: failureId,
      surfaceId: surfaceId,
      kind: kind,
    );
  }
}

/// The cutover deleted validation-only fault injection: there is no
/// `--cef-validation` switch, no `--cef-fault` point, and no `FaultPoint`
/// type. Recovery is driven only by real host, renderer, GPU, utility, and
/// profile observations through [RuntimeLifecycle]; production binaries
/// cannot select a fault path.

String _sanitize(String value, int maxLength) {
  final cleaned = value
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .split(RegExp(r'\s+'))
      .where((token) => token.isNotEmpty)
      .map(_sanitizeToken)
      .join(' ');
  return cleaned.length <= maxLength
      ? cleaned
      : cleaned.substring(0, maxLength);
}

/// Sanitize text before it enters the legacy surface event stream. Lifecycle
/// records apply the same policy internally, but adapters also emit the
/// original four-operation failure event for compatibility.
String sanitizeRuntimeMessage(String value) => _sanitize(value, 512);

String _sanitizeToken(String token) {
  final lower = token.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) {
    return '<redacted-url>';
  }
  if (RegExp(r'^(token|secret|password|cookie|profile[_-]?key)=')
      .hasMatch(lower)) {
    return '<redacted-secret>';
  }
  if (token.contains('/') ||
      token.contains(r'\') ||
      (token.length > 2 && token[1] == ':')) {
    return '<redacted-path>';
  }
  return token;
}

String _wireName(String value) => value.replaceAllMapped(
      RegExp(r'[A-Z]'),
      (match) => '_${match.group(0)!.toLowerCase()}',
    );

void _prune(List<int> values, int nowMs) {
  values.removeWhere((time) => nowMs - time >= restartWindowMs);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
