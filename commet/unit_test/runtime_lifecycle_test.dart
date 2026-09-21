import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

SurfaceSpec _spec() => SurfaceSpec(
      profileKey: ProfileKey('account-a'),
      presentation: PresentationMode.embedded,
      privacy: PrivacyMode.persistent,
      initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
      policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
    );

void main() {
  test('heartbeat timeout is observable and uses bounded backoff', () {
    final lifecycle = RuntimeLifecycle();
    lifecycle.start(0);
    lifecycle.hostReady(0);
    lifecycle.registerSurface(const SurfaceId(1), _spec());

    expect(
        lifecycle.tick(2000).first.kind.type, RuntimeEventType.heartbeatSent);
    final timeout = lifecycle.tick(10000);
    expect(
      timeout.any(
        (event) =>
            event.kind.type == RuntimeEventType.failure &&
            event.kind.failure!.kind == FailureClass.hostUnresponsive,
      ),
      isTrue,
    );
    expect(lifecycle.state, RuntimeState.restarting);
    expect(lifecycle.restartDueMs, 15250);
    final epoch = lifecycle.runtimeEpoch;
    lifecycle.start(15250);
    expect(lifecycle.runtimeEpoch, epoch + 1);
  });

  test('host loss distinguishes unacknowledged and acknowledged commands', () {
    final lifecycle = RuntimeLifecycle();
    lifecycle.start(0);
    lifecycle.hostReady(0);
    lifecycle.registerSurface(const SurfaceId(1), _spec());
    final failed =
        lifecycle.beginCommand(const SurfaceId(1), sideEffecting: true);
    final unknown =
        lifecycle.beginCommand(const SurfaceId(1), sideEffecting: true);
    lifecycle.acknowledgeCommand(unknown.commandId);

    final events = lifecycle.hostLost(1);
    expect(
      events.any(
        (event) =>
            event.kind.type == RuntimeEventType.commandOutcome &&
            event.kind.commandId == failed.commandId &&
            event.kind.outcome == CommandOutcome.failed,
      ),
      isTrue,
    );
    expect(
      events.any(
        (event) =>
            event.kind.type == RuntimeEventType.commandOutcome &&
            event.kind.commandId == unknown.commandId &&
            event.kind.outcome == CommandOutcome.unknown,
      ),
      isTrue,
    );
    expect(lifecycle.shouldReplayCommand(unknown.commandId), isFalse);
  });

  test('renderer and GPU failures stay within their recovery scopes', () {
    final lifecycle = RuntimeLifecycle();
    lifecycle.start(0);
    lifecycle.hostReady(0);
    lifecycle.registerSurface(const SurfaceId(1), _spec());

    final renderer = lifecycle.reportFailure(
      FailureClass.rendererCrash,
      1,
      rawStatus: 'TS_PROCESS_CRASHED',
      message: 'renderer exited',
    );
    expect(
      renderer.any(
        (event) =>
            event.kind.type == RuntimeEventType.surfaceRecovering &&
            event.surfaceId == const SurfaceId(1),
      ),
      isTrue,
    );
    expect(lifecycle.state, RuntimeState.ready);

    final gpu = lifecycle.reportFailure(
      FailureClass.gpuCrash,
      2,
      message: 'gpu exited',
    );
    expect(
      gpu.any(
        (event) =>
            event.kind.type == RuntimeEventType.stateChanged &&
            event.kind.state == RuntimeState.degraded,
      ),
      isTrue,
    );
    lifecycle.reportFailure(FailureClass.gpuCrash, 3,
        message: 'gpu exited again');
    expect(lifecycle.gpuDisabled, isTrue);
  });

  test('clean shutdown does not schedule recovery', () {
    final lifecycle = RuntimeLifecycle();
    lifecycle.start(0);
    lifecycle.hostReady(0);
    lifecycle.beginShutdown();
    final events = lifecycle.reportFailure(
      FailureClass.hostCrash,
      1,
      message: 'eof',
    );
    expect(
      events.any(
        (event) =>
            event.kind.type == RuntimeEventType.failure &&
            event.kind.failure!.kind == FailureClass.cleanStop,
      ),
      isTrue,
    );
    expect(
      events.any(
        (event) =>
            event.kind.type == RuntimeEventType.stateChanged &&
            event.kind.state == RuntimeState.restarting,
      ),
      isFalse,
    );
    expect(lifecycle.state, RuntimeState.stopping);
    lifecycle.finishShutdown(clean: true);
    expect(lifecycle.state, RuntimeState.stopped);
  });

  test('deterministic profile failures enter the terminal state', () {
    final lifecycle = RuntimeLifecycle();
    lifecycle.start(0);
    lifecycle.hostReady(0);
    final events = lifecycle.reportFailure(
      FailureClass.profileLocked,
      1,
      message: 'profile is locked',
    );
    expect(lifecycle.state, RuntimeState.failed);
    expect(
      events.any(
        (event) =>
            event.kind.type == RuntimeEventType.stateChanged &&
            event.kind.state == RuntimeState.failed,
      ),
      isTrue,
    );
  });

  test('fault injection parser is validation-only', () {
    expect(
      parseFaultPoint('hostCrash', validationBuild: true),
      FaultPoint.hostCrash,
    );
    expect(
      parseFaultPoint('host_crash', validationBuild: true),
      FaultPoint.hostCrash,
    );
    expect(parseFaultPoint('hostCrash', validationBuild: false), isNull);
    expect(parseFaultPoint('future', validationBuild: true), isNull);
  });

  test('diagnostics use the stable snake_case wire vocabulary', () {
    final lifecycle = RuntimeLifecycle();
    lifecycle.start(0);
    lifecycle.hostReady(0);
    final event = lifecycle
        .reportFailure(
          FailureClass.hostUnresponsive,
          1,
          message: 'heartbeat timeout',
        )
        .first;
    expect(event.toJson()['kind'], 'failure');
    expect(
      (event.toJson()['failure']! as Map<String, Object?>)['class'],
      'host_unresponsive',
    );
  });

  test('failure diagnostics redact URLs, paths, and secrets', () {
    final lifecycle = RuntimeLifecycle();
    lifecycle.start(0);
    lifecycle.hostReady(0);
    final failure = lifecycle
        .reportFailure(
          FailureClass.hostCrash,
          1,
          rawStatus: r'exit C:\private\profile',
          message: 'https://widget.test/page token=abc',
        )
        .first
        .kind
        .failure!;
    expect(failure.message, isNot(contains('https://')));
    expect(failure.message, isNot(contains('abc')));
    expect(failure.rawStatus, isNot(contains('private')));
  });
}
