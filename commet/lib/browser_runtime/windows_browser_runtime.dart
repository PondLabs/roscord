import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_ipc/dart_ipc.dart' as ipc;
import 'package:path/path.dart' as path;

import 'browser_runtime.dart';
import 'runtime_lifecycle.dart';

typedef BrowserHostConnector = Future<Socket> Function(String pipeName);
typedef BrowserHostStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// The Windows adapter for the out-of-process CEF host.
///
/// The host is started lazily on the first [open] and is shared by every
/// surface in this desktop process.  The adapter owns the authenticated pipe
/// client and translates the host's framed wire messages back into the public
/// [BrowserRuntime] seam.
class WindowsBrowserRuntime implements BrowserRuntime {
  WindowsBrowserRuntime({
    String? hostExecutable,
    BrowserHostConnector? connector,
    BrowserHostStarter? starter,
    int? parentProcessId,
    Random? random,
    this.connectTimeout = const Duration(seconds: 15),
    this.maxFrameBytes = defaultBrowserRuntimeMaxFrameBytes,
    this.validationBuild = false,
    this.faultPoint,
    this.forceSoftwareRendering = false,
    String? profileRoot,
  })  : _hostExecutable = hostExecutable,
        _connector = connector ?? ipc.connect,
        _starter = starter ?? _startProcess,
        _parentProcessId = parentProcessId ?? pid,
        _random = random ?? Random.secure(),
        _profileRoot = profileRoot,
        _events = StreamController<SurfaceEvent>.broadcast() {
    if (maxFrameBytes <= 0 || maxFrameBytes > 0xffffffff) {
      throw ArgumentError.value(maxFrameBytes, 'maxFrameBytes');
    }
    if (faultPoint != null && !validationBuild) {
      throw ArgumentError.value(
        faultPoint,
        'faultPoint',
        'fault injection requires validationBuild',
      );
    }
  }

  final Duration connectTimeout;
  final int maxFrameBytes;
  final bool validationBuild;
  final FaultPoint? faultPoint;
  // Forced software rendering keeps the CPU OnPaint frame ring authoritative
  // when GPU import is unavailable.  It never selects another browser engine;
  // the same frame/input/resize/focus contract applies.
  final bool forceSoftwareRendering;
  final String? _hostExecutable;
  final BrowserHostConnector _connector;
  final BrowserHostStarter _starter;
  final int _parentProcessId;
  final Random _random;
  final String? _profileRoot;
  final StreamController<SurfaceEvent> _events;
  final StreamController<RuntimeEvent> _runtimeEvents =
      StreamController<RuntimeEvent>.broadcast();
  final RuntimeLifecycle lifecycle = RuntimeLifecycle();
  final Map<SurfaceId, SurfaceSpec> _surfaces = {};
  final Map<SurfaceId, SurfaceId> _wireSurfaceIds = {};
  final Map<SurfaceId, int> _lastCommandSequences = {};
  final Map<SurfaceId, int> _nextEventSequences = {};
  final Map<int, Completer<SurfaceId>> _pendingOpens = {};
  final Map<SurfaceId, Completer<void>> _pendingCloses = {};
  final Map<int, SurfaceId> _restoreLogicalSurfaces = {};
  final Map<int, List<int>> _pendingCommandIds = {};
  final Map<int, Completer<void>> _pendingCommandResults = {};
  final Map<int, SurfaceId> _commandSurfaces = {};
  final Set<int> _commandsAwaitingTerminal = {};
  final Map<SurfaceId, List<int>> _acknowledgedCommands = {};
  final Set<SurfaceId> _restoredSurfaces = {};
  final Map<SurfaceId, Completer<void>> _pendingRestores = {};
  final Map<SurfaceId, ResizeCommand> _heldResizes = {};
  final Map<SurfaceId, FocusCommand> _heldFocus = {};
  final Set<int> _cancelledRestoreRequests = {};
  final Set<SurfaceId> _cancelledWireSurfaces = {};

  Future<void>? _startup;
  Process? _process;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketSubscription;
  FramedCodec? _codec;
  List<int> _readBuffer = [];
  Future<void> _writeTail = Future<void>.value();
  int _nextRequestId = 1;
  bool _disposed = false;
  bool _lost = false;
  bool _restoring = false;
  Timer? _heartbeatTimer;
  Timer? _restartTimer;

  @override
  Stream<SurfaceEvent> events() => _events.stream;

  /// Lifecycle diagnostics are additive to the original surface event stream.
  /// Surface callers keep the four BrowserRuntime operations while diagnostics
  /// can observe state, epoch, failure IDs and command outcomes.
  Stream<RuntimeEvent> runtimeEvents() => _runtimeEvents.stream;

  /// Feed a CEF child termination observation into the shared lifecycle
  /// policy. The host bridge uses this for renderer, GPU, utility, and
  /// profile callbacks without exposing a CEF object to Dart.
  void reportSurfaceFailure(
    SurfaceId surfaceId,
    FailureClass kind, {
    String? rawStatus,
    required String message,
  }) {
    _emitLifecycle(
      lifecycle.reportSurfaceFailure(
        surfaceId,
        kind,
        DateTime.now().millisecondsSinceEpoch,
        rawStatus: rawStatus,
        message: message,
      ),
    );
  }

  @override
  Future<SurfaceId> open(SurfaceSpec spec) async {
    _ensureUsable();
    _ensurePageOperationsAvailable();
    final requestId = _allocateRequestId();
    final pending = Completer<SurfaceId>();
    _pendingOpens[requestId] = pending;
    _openSpecs[requestId] = spec;
    try {
      await _ensureConnected();
      await _send(OpenWireMessage(requestId, spec));
      return await pending.future;
    } catch (_) {
      _pendingOpens.remove(requestId);
      _openSpecs.remove(requestId);
      rethrow;
    }
  }

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) async {
    _ensureUsable();
    command.validate();
    final spec = _surfaces[surfaceId];
    if (spec == null) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.staleSurface,
        'stale surface $surfaceId',
      );
    }
    if (command.profileKey != null && command.profileKey != spec.profileKey) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.profileMismatch,
        'surface profile key does not match',
      );
    }
    final previous = _lastCommandSequences[surfaceId] ?? 0;
    if (command.sequence <= previous) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.sequenceViolation,
        'sequence must be greater than $previous',
        expectedAfter: previous,
        received: command.sequence,
      );
    }
    final presentationCommand =
        command is ResizeCommand || command is FocusCommand;
    if (lifecycle.state == RuntimeState.restarting && presentationCommand) {
      _lastCommandSequences[surfaceId] = command.sequence;
      if (command is ResizeCommand) {
        _heldResizes[surfaceId] = command;
      } else if (command is FocusCommand) {
        _heldFocus[surfaceId] = command;
      }
      return;
    }
    _ensurePageOperationsAvailable();
    await _ensureConnected();
    final wireSurfaceId = _wireSurfaceIds[surfaceId] ?? surfaceId;
    final token = lifecycle.beginCommand(
      surfaceId,
      sideEffecting: command is! ResizeCommand && command is! FocusCommand,
    );
    final requestId = _allocateRequestId();
    final pendingForSequence = _pendingCommandIds.putIfAbsent(
      requestId,
      () => <int>[],
    );
    pendingForSequence.add(token.commandId);
    _commandSurfaces[token.commandId] = surfaceId;
    if (presentationCommand ||
        command is NavigateCommand ||
        command is ScriptCommand) {
      _commandsAwaitingTerminal.add(token.commandId);
    }
    _lastCommandSequences[surfaceId] = command.sequence;
    final result = Completer<void>();
    _pendingCommandResults[requestId] = result;
    try {
      await _send(CommandWireMessage(requestId, wireSurfaceId, command));
      await result.future;
    } catch (_) {
      _removePendingCommand(requestId, token.commandId);
      _pendingCommandResults.remove(requestId);
      _commandSurfaces.remove(token.commandId);
      _commandsAwaitingTerminal.remove(token.commandId);
      rethrow;
    }
  }

  @override
  Future<void> close(SurfaceId surfaceId) async {
    _ensureUsable();
    if (!_surfaces.containsKey(surfaceId)) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.staleSurface,
        'stale surface $surfaceId',
      );
    }
    if (lifecycle.state == RuntimeState.restarting || _restoring) {
      _cancelSurfaceRestore(surfaceId);
      return;
    }
    final existing = _pendingCloses[surfaceId];
    if (existing != null) return existing.future;
    final pending = Completer<void>();
    _pendingCloses[surfaceId] = pending;
    try {
      await _ensureConnected();
      await _send(CloseWireMessage(_wireSurfaceIds[surfaceId] ?? surfaceId));
      await pending.future;
    } catch (_) {
      _pendingCloses.remove(surfaceId);
      rethrow;
    }
  }

  /// Stops the shared host.  The application normally keeps one runtime for
  /// the desktop lifetime; this is provided for orderly test and shutdown
  /// paths.
  Future<void> dispose() async {
    if (_disposed) return;
    _emitLifecycle(lifecycle.beginShutdown());
    _disposed = true;
    _heartbeatTimer?.cancel();
    _restartTimer?.cancel();
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close();
    }
    final process = _process;
    _process = null;
    var cleanShutdown = true;
    if (process != null) {
      final exited = process.exitCode;
      if (!(await Future.any<bool>([
        exited.then((_) => true),
        Future<bool>.delayed(const Duration(seconds: 10), () => false),
      ]))) {
        cleanShutdown = false;
        process.kill();
        await process.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
      }
    }
    _completePendingWithError(
      const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime was disposed',
      ),
    );
    if (!cleanShutdown) {
      _emitLifecycle(
        lifecycle.reportFailure(
          FailureClass.shutdownTimeout,
          DateTime.now().millisecondsSinceEpoch,
          message: 'CEF host did not exit within the shutdown deadline',
        ),
      );
    }
    _emitLifecycle(lifecycle.finishShutdown(clean: cleanShutdown));
    await _events.close();
    await _runtimeEvents.close();
  }

  /// Starts one explicit retry after a terminal failure.  Automatic recovery
  /// never calls this method, so a failed runtime cannot enter a retry storm.
  Future<void> retryBrowser() async {
    _ensureUsable();
    _emitLifecycle(lifecycle.retry(DateTime.now().millisecondsSinceEpoch));
    await _ensureConnected(manualRetry: true);
  }

  Future<void> _ensureConnected({bool manualRetry = false}) async {
    if (!Platform.isWindows) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'the CEF browser runtime is only available on Windows',
      );
    }
    if (_socket != null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!manualRetry && lifecycle.state == RuntimeState.failed) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime is unavailable; use Retry browser',
      );
    }
    if (!manualRetry &&
        lifecycle.state == RuntimeState.restarting &&
        lifecycle.restartDueMs != null &&
        lifecycle.restartDueMs! > now) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime is restarting',
      );
    }
    final existing = _startup;
    if (existing != null) return existing;
    final startup = _startHost();
    _startup = startup;
    try {
      await startup;
    } catch (_) {
      if (!_disposed && !_lost && _socket != null) {
        _handleRuntimeLost('CEF host startup failed');
      }
      if (!_disposed && lifecycle.state == RuntimeState.starting) {
        _emitLifecycle(
          lifecycle.reportFailure(
            FailureClass.hostStartFailure,
            DateTime.now().millisecondsSinceEpoch,
            message: 'CEF host startup failed',
          ),
        );
      }
      if (identical(_startup, startup)) _startup = null;
      rethrow;
    }
  }

  Future<void> _startHost() async {
    _lost = false;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lifecycle.state != RuntimeState.starting) {
      try {
        _emitLifecycle(lifecycle.start(now));
      } on RuntimeLifecycleException {
        rethrow;
      }
    }
    final nonce = _newNonce();
    final pipeName = r'\\.\pipe\roscord-browser-' + '$_parentProcessId-$nonce';
    final executable = _resolveHostExecutable();
    final profileRoot = _resolveProfileRoot();
    final hostArguments = <String>[
      '--module=client.dll',
      '--pipe=$pipeName',
      '--nonce=$nonce',
      '--parent-pid=$_parentProcessId',
      '--profile-root=$profileRoot',
      if (forceSoftwareRendering) '--cef-software-rendering',
      if (validationBuild) '--cef-validation',
      if (faultPoint != null) '--cef-fault=${_faultName(faultPoint!)}',
    ];
    final process = await _startHostProcess(executable, hostArguments);
    _process = process;
    // The host does not write application output. Drain both handles so a
    // diagnostic cannot block process shutdown on a full OS pipe.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode.then((code) {
      if (!_disposed && identical(_process, process)) {
        _handleRuntimeLost(
          'CEF host exited',
          rawStatus: '$code',
        );
      }
    }));

    Socket? socket;
    Object? lastError;
    final deadline = DateTime.now().add(connectTimeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        socket = await _connector(pipeName).timeout(const Duration(seconds: 1));
        break;
      } catch (error) {
        lastError = error;
        if (!identical(_process, process)) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    if (socket == null) {
      if (identical(_process, process)) _process = null;
      process.kill();
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'could not connect to the Windows CEF host: ${sanitizeRuntimeMessage('$lastError')}',
      );
    }
    _codec = FramedCodec(nonce, maxFrameBytes: maxFrameBytes);
    _socket = socket;
    _socketSubscription = socket.listen(
      _onSocketData,
      onError: (Object error, StackTrace stackTrace) {
        _handleRuntimeLost('CEF host pipe failed: $error');
      },
      onDone: () => _handleRuntimeLost('CEF host pipe closed'),
      cancelOnError: true,
    );
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _tickLifecycle(),
    );
    _restoredSurfaces.clear();
    _cancelledRestoreRequests.clear();
    _cancelledWireSurfaces.clear();
    _restoring = true;
    try {
      await _restoreSurfaces();
    } finally {
      _restoring = false;
    }
    if (_lost || _disposed) return;
    _emitLifecycle(lifecycle.hostReady(DateTime.now().millisecondsSinceEpoch));
    for (final surfaceId in _restoredSurfaces.toList()) {
      unawaited(_flushHeldPresentationCommands(surfaceId));
    }
  }

  void _tickLifecycle() {
    if (_disposed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final events = lifecycle.tick(now);
    _emitLifecycle(events);
    final timedOut = events.any(
      (event) =>
          event.kind.type == RuntimeEventType.failure &&
          event.kind.failure?.kind == FailureClass.hostUnresponsive,
    );
    if (timedOut) {
      _handleRuntimeLost(
        'CEF host heartbeat timed out',
        failureClass: FailureClass.hostUnresponsive,
        lifecycleAlreadyReported: true,
      );
      return;
    }
    for (final event in events) {
      if (event.kind.type == RuntimeEventType.heartbeatSent) {
        final requestId = event.kind.requestId;
        if (requestId != null) {
          unawaited(_send(HeartbeatWireMessage(requestId)).catchError((_) {}));
        }
      }
    }
    if (lifecycle.state == RuntimeState.restarting) _scheduleRestart();
  }

  void _scheduleRestart() {
    if (_restartTimer != null || _disposed) return;
    final due = lifecycle.restartDueMs;
    if (due == null) return;
    final delay = due - DateTime.now().millisecondsSinceEpoch;
    _restartTimer = Timer(
      Duration(milliseconds: delay > 0 ? delay : 0),
      () async {
        _restartTimer = null;
        if (_disposed || !lifecycle.restartReady) return;
        try {
          await _ensureConnected();
        } on Object catch (error) {
          _emitLifecycle(
            lifecycle.reportFailure(
              FailureClass.hostStartFailure,
              DateTime.now().millisecondsSinceEpoch,
              message: 'automatic browser restart failed: $error',
            ),
          );
        }
      },
    );
  }

  Future<void> _restoreSurfaces() async {
    _pendingRestores.clear();
    final restoreCompletions = <Future<void>>[];
    for (final entry in _surfaces.entries.toList()
      ..sort((a, b) => a.key.value.compareTo(b.key.value))) {
      if (!_surfaces.containsKey(entry.key)) continue;
      final requestId = _allocateRequestId();
      final restored = Completer<void>();
      _pendingRestores[entry.key] = restored;
      restoreCompletions.add(restored.future);
      _openSpecs[requestId] = entry.value;
      _restoreLogicalSurfaces[requestId] = entry.key;
      await _send(OpenWireMessage(requestId, entry.value));
    }
    await Future.wait(restoreCompletions);
  }

  Future<Process> _startHostProcess(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await _starter(executable, arguments);
    } on Object catch (error) {
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'could not start the Windows CEF host: ${sanitizeRuntimeMessage('$error')}',
      );
    }
  }

  String _resolveHostExecutable() {
    if (_hostExecutable != null) return _hostExecutable;
    final executableDirectory = path.dirname(Platform.resolvedExecutable);
    final candidates = [
      path.join(executableDirectory, 'cef_host', 'cef_host.exe'),
      path.join(executableDirectory, 'cef_host.exe'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    throw BrowserRuntimeException(
      BrowserRuntimeErrorCode.protocol,
      'bundled cef_host.exe was not found in ${candidates.join(', ')}',
    );
  }

  String _newNonce() => List<String>.generate(
        32,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();

  int _allocateRequestId() {
    final requestId = _nextRequestId;
    _nextRequestId++;
    if (_nextRequestId > 0x7fffffff) _nextRequestId = 1;
    return requestId;
  }

  Future<void> _send(WireMessage message) {
    final codec = _codec;
    final socket = _socket;
    if (codec == null || socket == null) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime is not connected',
      );
    }
    final frame = codec.encode(message);
    final write = _writeTail.then((_) async {
      socket.add(frame);
      await socket.flush();
    });
    _writeTail = write.catchError((Object error, StackTrace stackTrace) {
      _handleRuntimeLost('CEF host write failed: $error');
      Error.throwWithStackTrace(error, stackTrace);
    });
    return write;
  }

  void _onSocketData(Uint8List data) {
    if (_disposed || _lost) return;
    _readBuffer.addAll(data);
    final codec = _codec;
    if (codec == null) return;
    while (_readBuffer.length >= 4) {
      try {
        final declared = ByteData.sublistView(
          Uint8List.fromList(_readBuffer),
        ).getUint32(0, Endian.big);
        if (declared > maxFrameBytes ||
            (_readBuffer.length < declared + 4 &&
                _readBuffer.length > maxFrameBytes + 4)) {
          _handleRuntimeLost(
            'CEF host sent an oversized frame',
            failureClass: FailureClass.hostProtocolViolation,
          );
          return;
        }
        final decoded = codec.decodeNext(Uint8List.fromList(_readBuffer));
        if (decoded == null) return;
        _readBuffer = _readBuffer.sublist(decoded.consumedBytes);
        _onWireMessage(decoded.message);
      } on Object catch (error) {
        _handleRuntimeLost(
          'CEF host sent an invalid frame: $error',
          failureClass: FailureClass.hostProtocolViolation,
        );
        return;
      }
    }
  }

  void _onWireMessage(WireMessage message) {
    switch (message) {
      case OpenedWireMessage(:final requestId, :final surfaceId):
        if (_cancelledRestoreRequests.remove(requestId)) {
          _openSpecs.remove(requestId);
          _cancelledWireSurfaces.add(surfaceId);
          unawaited(
            _send(CloseWireMessage(surfaceId)).catchError((_) {}),
          );
          return;
        }
        final pending = _pendingOpens.remove(requestId);
        final restoredLogicalId = _restoreLogicalSurfaces.remove(requestId);
        if (pending == null && restoredLogicalId == null) {
          _handleRuntimeLost('CEF host acknowledged an unknown open request');
          return;
        }
        final spec = _openSpecs.remove(requestId);
        if (spec == null) {
          pending?.completeError(
            const BrowserRuntimeException(
              BrowserRuntimeErrorCode.protocol,
              'CEF host acknowledged an open without a spec',
            ),
          );
          _handleRuntimeLost('CEF host acknowledged an open without a spec');
          return;
        }
        final logicalId = restoredLogicalId ?? surfaceId;
        _surfaces[logicalId] = spec;
        _wireSurfaceIds[logicalId] = surfaceId;
        _lastCommandSequences.putIfAbsent(logicalId, () => 0);
        _nextEventSequences[logicalId] = 2;
        lifecycle.registerSurface(logicalId, spec);
        if (pending != null && !pending.isCompleted)
          pending.complete(logicalId);
        if (restoredLogicalId != null) {
          _restoredSurfaces.add(logicalId);
        }
      case HeartbeatAckWireMessage(:final requestId):
        try {
          _emitLifecycle(
            [
              lifecycle.heartbeatAck(
                requestId,
                DateTime.now().millisecondsSinceEpoch,
              ),
            ],
          );
        } on RuntimeLifecycleException {
          _handleRuntimeLost(
            'CEF host acknowledged an unknown heartbeat',
            failureClass: FailureClass.hostProtocolViolation,
          );
        }
      case AckWireMessage(:final requestId):
        final pendingIds = _pendingCommandIds[requestId];
        if (pendingIds == null || pendingIds.isEmpty) {
          _handleRuntimeLost(
            'CEF host acknowledged an unknown command',
            failureClass: FailureClass.hostProtocolViolation,
          );
          return;
        }
        final commandId = pendingIds.removeAt(0);
        lifecycle.acknowledgeCommand(commandId);
        final surfaceId = _commandSurfaces[commandId];
        if (surfaceId != null &&
            _commandsAwaitingTerminal.contains(commandId)) {
          _acknowledgedCommands
              .putIfAbsent(surfaceId, () => <int>[])
              .add(commandId);
        } else {
          lifecycle.completeCommand(commandId);
          _commandSurfaces.remove(commandId);
        }
        _pendingCommandResults.remove(requestId)?.complete();
        if (pendingIds.isEmpty) _pendingCommandIds.remove(requestId);
      case EventWireMessage(:final event):
        _onSurfaceEvent(event);
      case ErrorWireMessage(:final requestId, :final code, :final message):
        final pending =
            requestId == null ? null : _pendingOpens.remove(requestId);
        if (pending != null) {
          pending.completeError(_runtimeError(code, message));
        } else {
          final restoredLogicalId = requestId == null
              ? null
              : _restoreLogicalSurfaces.remove(requestId);
          if (restoredLogicalId != null) {
            final restored = _pendingRestores.remove(restoredLogicalId);
            if (restored != null && !restored.isCompleted) {
              restored.completeError(_runtimeError(code, message));
            }
          }
          final pendingCommands =
              requestId == null ? null : _pendingCommandIds.remove(requestId);
          if (pendingCommands != null) {
            for (final commandId in pendingCommands) {
              try {
                lifecycle.completeCommand(commandId);
              } on Object {
                // A concurrent transport-loss event may already have
                // resolved this ledger entry.
              }
              _commandSurfaces.remove(commandId);
              _commandsAwaitingTerminal.remove(commandId);
            }
          }
          if (requestId != null) {
            _pendingCommandResults
                .remove(requestId)
                ?.completeError(_runtimeError(code, message));
          }
          _publishFailure(code, message);
        }
      case HeartbeatWireMessage():
        _handleRuntimeLost(
          'CEF host sent a heartbeat request to its parent',
          failureClass: FailureClass.hostProtocolViolation,
        );
      case OpenWireMessage() || CommandWireMessage() || CloseWireMessage():
        _handleRuntimeLost(
          'CEF host sent a request to its parent',
          failureClass: FailureClass.hostProtocolViolation,
        );
    }
  }

  final Map<int, SurfaceSpec> _openSpecs = {};

  void _onSurfaceEvent(SurfaceEvent event) {
    if (_cancelledWireSurfaces.contains(event.surfaceId)) {
      if (event is ClosedEvent) {
        _cancelledWireSurfaces.remove(event.surfaceId);
      }
      return;
    }
    final logicalSurfaceId = _wireSurfaceIds.entries
        .firstWhere(
          (entry) => entry.value == event.surfaceId,
          orElse: () => MapEntry(event.surfaceId, event.surfaceId),
        )
        .key;
    final surface = _surfaces[logicalSurfaceId];
    if (surface == null && event is! ReadyEvent) {
      _publishFailure('stale_surface', 'event references an unknown surface');
      return;
    }
    if (event is ClosedEvent) {
      _surfaces.remove(logicalSurfaceId);
      _wireSurfaceIds.remove(logicalSurfaceId);
      _lastCommandSequences.remove(logicalSurfaceId);
      _nextEventSequences.remove(logicalSurfaceId);
      if (lifecycle.surfaceSpec(logicalSurfaceId) != null) {
        lifecycle.removeSurface(logicalSurfaceId);
      }
      _heldResizes.remove(logicalSurfaceId);
      _heldFocus.remove(logicalSurfaceId);
      final acknowledged = _acknowledgedCommands.remove(logicalSurfaceId);
      if (acknowledged != null) {
        for (final commandId in acknowledged) {
          lifecycle.completeCommand(commandId);
          _commandSurfaces.remove(commandId);
          _commandsAwaitingTerminal.remove(commandId);
        }
      }
      final pending = _pendingCloses.remove(logicalSurfaceId);
      if (pending != null && !pending.isCompleted) pending.complete();
      final restored = _pendingRestores.remove(logicalSurfaceId);
      if (restored != null && !restored.isCompleted) {
        restored.completeError(
          const BrowserRuntimeException(
            BrowserRuntimeErrorCode.protocol,
            'CEF host closed a surface during restoration',
          ),
        );
      }
    }
    final mapped = event.surfaceId == logicalSurfaceId
        ? event
        : (() {
            final encoded = Map<String, dynamic>.from(event.toJson());
            final payload = Map<String, dynamic>.from(
              encoded['payload']! as Map,
            );
            payload['surface_id'] = logicalSurfaceId.value;
            encoded['payload'] = payload;
            return SurfaceEvent.fromJson(encoded);
          })();
    if (mapped is NavigationEvent ||
        mapped is WindowChangedEvent ||
        mapped is ScriptMessageEvent) {
      final acknowledged = _acknowledgedCommands[logicalSurfaceId];
      if (acknowledged != null && acknowledged.isNotEmpty) {
        final commandId = acknowledged.removeAt(0);
        lifecycle.completeCommand(commandId);
        _commandSurfaces.remove(commandId);
        _commandsAwaitingTerminal.remove(commandId);
        if (acknowledged.isEmpty) {
          _acknowledgedCommands.remove(logicalSurfaceId);
        }
      }
    }
    _events.add(mapped);
    if (event is ReadyEvent) {
      _restoredSurfaces.add(logicalSurfaceId);
      final restored = _pendingRestores.remove(logicalSurfaceId);
      if (restored != null && !restored.isCompleted) restored.complete();
    }
  }

  void _publishFailure(String code, String message) {
    final safeMessage = sanitizeRuntimeMessage(message);
    final failureClass = _failureClass(code);
    if (failureClass != null) {
      for (final surfaceId in _surfaces.keys.toList()) {
        if (lifecycle.surfaceSpec(surfaceId) == null) continue;
        _emitLifecycle(
          lifecycle.reportSurfaceFailure(
            surfaceId,
            failureClass,
            DateTime.now().millisecondsSinceEpoch,
            message: safeMessage,
          ),
        );
      }
    }
    for (final surfaceId in _surfaces.keys.toList()) {
      final sequence = _nextEventSequences[surfaceId] ?? 1;
      _nextEventSequences[surfaceId] = sequence + 1;
      _events.add(
        FailedEvent(
          surfaceId,
          sequence,
          SurfaceFailure(_failureKind(code), safeMessage),
        ),
      );
    }
  }

  void _handleRuntimeLost(
    String message, {
    FailureClass failureClass = FailureClass.hostCrash,
    String? rawStatus,
    bool lifecycleAlreadyReported = false,
  }) {
    if (_lost || _disposed) return;
    _lost = true;
    final socket = _socket;
    _socket = null;
    socket?.destroy();
    _startup = null;
    _codec = null;
    _readBuffer = [];
    _restoreLogicalSurfaces.clear();
    _restoredSurfaces.clear();
    _cancelledRestoreRequests.clear();
    _cancelledWireSurfaces.clear();
    for (final restored in _pendingRestores.values) {
      if (!restored.isCompleted)
        restored.completeError(
          BrowserRuntimeException(
            BrowserRuntimeErrorCode.protocol,
            sanitizeRuntimeMessage(message),
          ),
        );
    }
    _pendingRestores.clear();
    _openSpecs.clear();
    _pendingCommandIds.clear();
    _commandSurfaces.clear();
    _commandsAwaitingTerminal.clear();
    _acknowledgedCommands.clear();
    for (final result in _pendingCommandResults.values) {
      if (!result.isCompleted) {
        result.completeError(
          BrowserRuntimeException(
            BrowserRuntimeErrorCode.protocol,
            sanitizeRuntimeMessage(message),
          ),
        );
      }
    }
    _pendingCommandResults.clear();
    final subscription = _socketSubscription;
    _socketSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    final process = _process;
    _process = null;
    process?.kill();
    _completePendingWithError(
      BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        sanitizeRuntimeMessage(message),
      ),
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!lifecycleAlreadyReported) {
      _emitLifecycle(
        failureClass == FailureClass.hostProtocolViolation
            ? lifecycle.hostProtocolViolation(now, message: message)
            : lifecycle.hostLost(
                now,
                message: message,
                rawStatus: rawStatus,
              ),
      );
    }
    _publishFailure('runtime_lost', message);
    _scheduleRestart();
  }

  Future<void> _flushHeldPresentationCommands(
      SurfaceId logicalSurfaceId) async {
    final held = <SurfaceCommand>[];
    final resize = _heldResizes[logicalSurfaceId];
    if (resize != null) held.add(resize);
    final focus = _heldFocus[logicalSurfaceId];
    if (focus != null) held.add(focus);
    held.sort((a, b) => a.sequence.compareTo(b.sequence));
    _heldResizes.remove(logicalSurfaceId);
    _heldFocus.remove(logicalSurfaceId);
    final wireSurfaceId = _wireSurfaceIds[logicalSurfaceId];
    if (wireSurfaceId == null || held.isEmpty || _disposed) return;
    for (final command in held) {
      CommandToken? token;
      int? requestId;
      try {
        token = lifecycle.beginCommand(
          logicalSurfaceId,
          sideEffecting: false,
        );
        requestId = _allocateRequestId();
        _pendingCommandIds
            .putIfAbsent(requestId, () => <int>[])
            .add(token.commandId);
        _commandSurfaces[token.commandId] = logicalSurfaceId;
        _commandsAwaitingTerminal.add(token.commandId);
        await _send(CommandWireMessage(requestId, wireSurfaceId, command));
      } catch (_) {
        final commandToken = token;
        if (commandToken != null && requestId != null) {
          _removePendingCommand(requestId, commandToken.commandId);
          _commandSurfaces.remove(commandToken.commandId);
          _commandsAwaitingTerminal.remove(commandToken.commandId);
        }
        return;
      }
    }
  }

  void _emitLifecycle(Iterable<RuntimeEvent> events) {
    if (_runtimeEvents.isClosed) return;
    for (final event in events) {
      _runtimeEvents.add(event);
    }
  }

  void _removePendingCommand(int requestId, int commandId) {
    final pending = _pendingCommandIds[requestId];
    if (pending == null) return;
    pending.remove(commandId);
    if (pending.isEmpty) _pendingCommandIds.remove(requestId);
    _commandSurfaces.remove(commandId);
    _commandsAwaitingTerminal.remove(commandId);
  }

  void _completePendingWithError(Object error) {
    for (final pending in _pendingOpens.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pendingOpens.clear();
    _openSpecs.clear();
    for (final pending in _pendingCloses.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pendingCloses.clear();
    for (final restored in _pendingRestores.values) {
      if (!restored.isCompleted) restored.completeError(error);
    }
    _pendingRestores.clear();
    for (final result in _pendingCommandResults.values) {
      if (!result.isCompleted) result.completeError(error);
    }
    _pendingCommandResults.clear();
  }

  void _cancelSurfaceRestore(SurfaceId surfaceId) {
    final wireSurfaceId = _wireSurfaceIds.remove(surfaceId);
    if (wireSurfaceId != null) _cancelledWireSurfaces.add(wireSurfaceId);
    _surfaces.remove(surfaceId);
    _restoredSurfaces.remove(surfaceId);
    _lastCommandSequences.remove(surfaceId);
    _nextEventSequences.remove(surfaceId);
    _heldResizes.remove(surfaceId);
    _heldFocus.remove(surfaceId);
    final acknowledged = _acknowledgedCommands.remove(surfaceId);
    if (acknowledged != null) {
      for (final commandId in acknowledged) {
        lifecycle.completeCommand(commandId);
        _commandSurfaces.remove(commandId);
        _commandsAwaitingTerminal.remove(commandId);
      }
    }
    final restored = _pendingRestores.remove(surfaceId);
    if (restored != null && !restored.isCompleted) restored.complete();
    for (final entry in _restoreLogicalSurfaces.entries.toList()) {
      if (entry.value != surfaceId) continue;
      _restoreLogicalSurfaces.remove(entry.key);
      _openSpecs.remove(entry.key);
      _cancelledRestoreRequests.add(entry.key);
    }
    if (lifecycle.surfaceSpec(surfaceId) != null) {
      lifecycle.removeSurface(surfaceId);
    }
    if (wireSurfaceId != null && _socket != null) {
      unawaited(_send(CloseWireMessage(wireSurfaceId)).catchError((_) {}));
    }
  }

  BrowserRuntimeException _runtimeError(String code, String message) =>
      BrowserRuntimeException(
          _errorCode(code), sanitizeRuntimeMessage(message));

  BrowserRuntimeErrorCode _errorCode(String code) => switch (code) {
        'invalid_spec' => BrowserRuntimeErrorCode.invalidSpec,
        'invalid_command' => BrowserRuntimeErrorCode.invalidCommand,
        'unknown_surface' => BrowserRuntimeErrorCode.unknownSurface,
        'stale_surface' => BrowserRuntimeErrorCode.staleSurface,
        'sequence_violation' => BrowserRuntimeErrorCode.sequenceViolation,
        'profile_mismatch' => BrowserRuntimeErrorCode.profileMismatch,
        'profile_busy' => BrowserRuntimeErrorCode.profileBusy,
        'profile_corrupt' => BrowserRuntimeErrorCode.profileCorrupt,
        'profile_unavailable' => BrowserRuntimeErrorCode.profileUnavailable,
        'migration_failed' => BrowserRuntimeErrorCode.migrationFailed,
        'certificate_error' => BrowserRuntimeErrorCode.certificateDenied,
        'client_certificate_denied' =>
          BrowserRuntimeErrorCode.clientCertificateDenied,
        'policy_violation' || 'popup_blocked' || 'stale_popup' ||
        'unknown_permission_request' =>
          BrowserRuntimeErrorCode.policyViolation,
        _ => BrowserRuntimeErrorCode.protocol,
      };

  FailureKind _failureKind(String code) => switch (code) {
        'profile_mismatch' => FailureKind.profileMismatch,
        'sequence_violation' ||
        'invalid_command' =>
          FailureKind.protocolViolation,
        'invalid_spec' || 'navigation_blocked' => FailureKind.navigationBlocked,
        'certificate_error' => FailureKind.certificateDenied,
        'client_certificate_denied' => FailureKind.clientCertificateDenied,
        'policy_violation' || 'popup_blocked' || 'stale_popup' ||
        'unknown_permission_request' =>
          FailureKind.policyViolation,
        'permission_denied' => FailureKind.permissionDenied,
        'capture_denied' => FailureKind.captureDenied,
        'malformed_message' => FailureKind.malformedMessage,
        'frame_too_large' => FailureKind.oversizedMessage,
        'unknown_message' => FailureKind.unknownMessage,
        _ => FailureKind.runtimeLost,
      };

  FailureClass? _failureClass(String code) => switch (code) {
        'renderer_crash' => FailureClass.rendererCrash,
        'renderer_oom' => FailureClass.rendererOom,
        'renderer_killed' => FailureClass.rendererKilled,
        'renderer_abnormal_exit' => FailureClass.rendererAbnormalExit,
        'renderer_launch_failed' => FailureClass.rendererLaunchFailed,
        'renderer_integrity_failure' => FailureClass.rendererIntegrityFailure,
        'renderer_unresponsive' => FailureClass.rendererUnresponsive,
        'gpu_crash' => FailureClass.gpuCrash,
        'gpu_launch_failed' => FailureClass.gpuLaunchFailed,
        'utility_crash' => FailureClass.utilityCrash,
        'network_service_failure' => FailureClass.networkServiceFailure,
        'utility_launch_failed' => FailureClass.utilityLaunchFailed,
        'profile_locked' => FailureClass.profileLocked,
        'profile_corrupt' || 'migration_failed' => FailureClass.profileCorrupt,
        'profile_unavailable' || 'profile_busy' =>
          FailureClass.profileUnavailable,
        _ => null,
      };

  String _resolveProfileRoot() {
    final configured = _profileRoot;
    if (configured != null && configured.isNotEmpty) return configured;
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'];
    if (base == null || base.isEmpty) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.profileUnavailable,
        'Windows profile root is unavailable',
      );
    }
    return path.join(base, 'roscord', 'cef', 'profiles');
  }

  String _faultName(FaultPoint point) => point.name.replaceAllMapped(
        RegExp(r'[A-Z]'),
        (match) => '_${match.group(0)!.toLowerCase()}',
      );

  void _ensureUsable() {
    if (_disposed) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime was disposed',
      );
    }
  }

  void _ensurePageOperationsAvailable() {
    if (lifecycle.state == RuntimeState.restarting ||
        lifecycle.state == RuntimeState.failed ||
        lifecycle.state == RuntimeState.stopping) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime is temporarily unavailable',
      );
    }
  }

  static Future<Process> _startProcess(
    String executable,
    List<String> arguments,
  ) =>
      Process.start(
        executable,
        arguments,
        runInShell: false,
        workingDirectory: path.dirname(executable),
      );
}
