import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_ipc/dart_ipc.dart' as ipc;
import 'package:path/path.dart' as path;

import 'browser_runtime.dart';

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
  })  : _hostExecutable = hostExecutable,
        _connector = connector ?? ipc.connect,
        _starter = starter ?? _startProcess,
        _parentProcessId = parentProcessId ?? pid,
        _random = random ?? Random.secure(),
        _events = StreamController<SurfaceEvent>.broadcast() {
    if (maxFrameBytes <= 0 || maxFrameBytes > 0xffffffff) {
      throw ArgumentError.value(maxFrameBytes, 'maxFrameBytes');
    }
  }

  final Duration connectTimeout;
  final int maxFrameBytes;
  final String? _hostExecutable;
  final BrowserHostConnector _connector;
  final BrowserHostStarter _starter;
  final int _parentProcessId;
  final Random _random;
  final StreamController<SurfaceEvent> _events;
  final Map<SurfaceId, SurfaceSpec> _surfaces = {};
  final Map<SurfaceId, int> _lastCommandSequences = {};
  final Map<SurfaceId, int> _nextEventSequences = {};
  final Map<int, Completer<SurfaceId>> _pendingOpens = {};
  final Map<SurfaceId, Completer<void>> _pendingCloses = {};

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

  @override
  Stream<SurfaceEvent> events() => _events.stream;

  @override
  Future<SurfaceId> open(SurfaceSpec spec) async {
    _ensureUsable();
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
    await _ensureConnected();
    _lastCommandSequences[surfaceId] = command.sequence;
    await _send(CommandWireMessage(surfaceId, command));
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
    final existing = _pendingCloses[surfaceId];
    if (existing != null) return existing.future;
    final pending = Completer<void>();
    _pendingCloses[surfaceId] = pending;
    try {
      await _ensureConnected();
      await _send(CloseWireMessage(surfaceId));
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
    _disposed = true;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      await socket.close();
    }
    final process = _process;
    _process = null;
    if (process != null) {
      final exited = process.exitCode;
      if (!(await Future.any<bool>([
        exited.then((_) => true),
        Future<bool>.delayed(const Duration(seconds: 2), () => false),
      ]))) {
        process.kill();
      }
    }
    _completePendingWithError(
      const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime was disposed',
      ),
    );
    await _events.close();
  }

  Future<void> _ensureConnected() async {
    if (!Platform.isWindows) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'the CEF browser runtime is only available on Windows',
      );
    }
    if (_socket != null) return;
    final existing = _startup;
    if (existing != null) return existing;
    final startup = _startHost();
    _startup = startup;
    try {
      await startup;
    } catch (_) {
      if (identical(_startup, startup)) _startup = null;
      rethrow;
    }
  }

  Future<void> _startHost() async {
    _lost = false;
    final nonce = _newNonce();
    final pipeName = r'\\.\pipe\roscord-browser-' + '$_parentProcessId-$nonce';
    final executable = _resolveHostExecutable();
    final process = await _startHostProcess(executable, [
      '--module=client.dll',
      '--pipe=$pipeName',
      '--nonce=$nonce',
      '--parent-pid=$_parentProcessId',
    ]);
    _process = process;
    // The host does not write application output. Drain both handles so a
    // diagnostic cannot block process shutdown on a full OS pipe.
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode.then((code) {
      if (!_disposed && identical(_process, process)) {
        _handleRuntimeLost('CEF host exited with code $code');
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
      process.kill();
      throw BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'could not connect to the Windows CEF host: $lastError',
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
        'could not start the Windows CEF host: $error',
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
          _handleRuntimeLost('CEF host sent an oversized frame');
          return;
        }
        final decoded = codec.decodeNext(Uint8List.fromList(_readBuffer));
        if (decoded == null) return;
        _readBuffer = _readBuffer.sublist(decoded.consumedBytes);
        _onWireMessage(decoded.message);
      } on Object catch (error) {
        _handleRuntimeLost('CEF host sent an invalid frame: $error');
        return;
      }
    }
  }

  void _onWireMessage(WireMessage message) {
    switch (message) {
      case OpenedWireMessage(:final requestId, :final surfaceId):
        final pending = _pendingOpens.remove(requestId);
        if (pending == null || pending.isCompleted) {
          _handleRuntimeLost('CEF host acknowledged an unknown open request');
          return;
        }
        final spec = _openSpecs.remove(requestId);
        if (spec == null) {
          pending.completeError(
            const BrowserRuntimeException(
              BrowserRuntimeErrorCode.protocol,
              'CEF host acknowledged an open without a spec',
            ),
          );
          _handleRuntimeLost('CEF host acknowledged an open without a spec');
          return;
        }
        _surfaces[surfaceId] = spec;
        _lastCommandSequences[surfaceId] = 0;
        _nextEventSequences[surfaceId] = 2;
        pending.complete(surfaceId);
      case EventWireMessage(:final event):
        _onSurfaceEvent(event);
      case ErrorWireMessage(:final requestId, :final code, :final message):
        final pending =
            requestId == null ? null : _pendingOpens.remove(requestId);
        if (pending != null) {
          pending.completeError(_runtimeError(code, message));
        } else {
          _publishFailure(code, message);
        }
      case AckWireMessage():
        // The first host milestone does not use acknowledgements.
        break;
      case OpenWireMessage() || CommandWireMessage() || CloseWireMessage():
        _handleRuntimeLost('CEF host sent a request to its parent');
    }
  }

  final Map<int, SurfaceSpec> _openSpecs = {};

  void _onSurfaceEvent(SurfaceEvent event) {
    final surface = _surfaces[event.surfaceId];
    if (surface == null && event is! ReadyEvent) {
      _publishFailure('stale_surface', 'event references an unknown surface');
      return;
    }
    if (event is ClosedEvent) {
      _surfaces.remove(event.surfaceId);
      _lastCommandSequences.remove(event.surfaceId);
      _nextEventSequences.remove(event.surfaceId);
      final pending = _pendingCloses.remove(event.surfaceId);
      if (pending != null && !pending.isCompleted) pending.complete();
    }
    _events.add(event);
  }

  void _publishFailure(String code, String message) {
    for (final surfaceId in _surfaces.keys.toList()) {
      final sequence = _nextEventSequences[surfaceId] ?? 1;
      _nextEventSequences[surfaceId] = sequence + 1;
      _events.add(
        FailedEvent(
          surfaceId,
          sequence,
          SurfaceFailure(_failureKind(code), message),
        ),
      );
    }
  }

  void _handleRuntimeLost(String message) {
    if (_lost || _disposed) return;
    _lost = true;
    _socket = null;
    _startup = null;
    final process = _process;
    _process = null;
    process?.kill();
    _completePendingWithError(
      BrowserRuntimeException(BrowserRuntimeErrorCode.protocol, message),
    );
    _publishFailure('runtime_lost', message);
    _surfaces.clear();
    _lastCommandSequences.clear();
    _nextEventSequences.clear();
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
  }

  BrowserRuntimeException _runtimeError(String code, String message) =>
      BrowserRuntimeException(_errorCode(code), message);

  BrowserRuntimeErrorCode _errorCode(String code) => switch (code) {
        'invalid_spec' => BrowserRuntimeErrorCode.invalidSpec,
        'invalid_command' => BrowserRuntimeErrorCode.invalidCommand,
        'unknown_surface' => BrowserRuntimeErrorCode.unknownSurface,
        'stale_surface' => BrowserRuntimeErrorCode.staleSurface,
        'sequence_violation' => BrowserRuntimeErrorCode.sequenceViolation,
        'profile_mismatch' => BrowserRuntimeErrorCode.profileMismatch,
        _ => BrowserRuntimeErrorCode.protocol,
      };

  FailureKind _failureKind(String code) => switch (code) {
        'profile_mismatch' => FailureKind.profileMismatch,
        'sequence_violation' ||
        'invalid_command' =>
          FailureKind.protocolViolation,
        'invalid_spec' || 'navigation_blocked' => FailureKind.navigationBlocked,
        'malformed_message' => FailureKind.malformedMessage,
        'frame_too_large' => FailureKind.oversizedMessage,
        'unknown_message' => FailureKind.unknownMessage,
        _ => FailureKind.runtimeLost,
      };

  void _ensureUsable() {
    if (_disposed) {
      throw const BrowserRuntimeException(
        BrowserRuntimeErrorCode.protocol,
        'browser runtime was disposed',
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
