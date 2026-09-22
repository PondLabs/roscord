import 'package:commet/browser_runtime.dart';
import 'package:test/test.dart';

SurfaceSpec _spec(String profile, PresentationMode presentation, String url) {
  return SurfaceSpec(
    profileKey: ProfileKey(profile),
    presentation: presentation,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: url),
    policy: SurfacePolicy(
      allowedOrigins: [Uri.parse(url).replace(path: '').toString()],
    ),
  );
}

SurfaceSpec _embeddedSpec(String profile) =>
    _spec(profile, PresentationMode.embedded, 'https://widgets.test/view');

SurfaceSpec _standaloneSpec(String profile) =>
    _spec(profile, PresentationMode.standalone, 'https://widgets.test/view');

void main() {
  group('host restart restores only declarative state in stable order', () {
    test('restore plan is in stable SurfaceId order', () {
      final coordinator = SurfaceRecoveryCoordinator();
      coordinator.registerSurface(
        const SurfaceId(9),
        _embeddedSpec('account-a'),
      );
      coordinator.registerSurface(
        const SurfaceId(3),
        _standaloneSpec('account-a'),
      );
      coordinator.registerSurface(
        const SurfaceId(7),
        _embeddedSpec('account-b'),
      );
      final plan = coordinator.restorePlan();
      expect(
        plan.map((snapshot) => snapshot.surfaceId.value),
        [3, 7, 9],
      );
    });

    test('only declarative spec plus held presentation is restored', () {
      final coordinator = SurfaceRecoveryCoordinator();
      coordinator.registerSurface(
        const SurfaceId(1),
        _embeddedSpec('account-a'),
      );
      coordinator.setPresentationValue(
        const SurfaceId(1),
        'size',
        '1280x720@1.0',
      );
      coordinator.setPresentationValue(
        const SurfaceId(1),
        'focus',
        'true',
      );
      final snapshot = coordinator.restorePlan().single;
      expect(snapshot.spec.initialNavigation.url, 'https://widgets.test/view');
      expect(snapshot.presentation['size'], '1280x720@1.0');
      expect(snapshot.presentation['focus'], 'true');
      // No history, page state, pending permissions, downloads, clipboard,
      // or capture handles are stored.
      expect(snapshot.toJson().keys,
          containsAll(['surface_id', 'profile_key_hash', 'presentation']));
      expect(snapshot.presentation.keys, isNot(contains('history')));
      expect(snapshot.presentation.keys, isNot(contains('pending_permission')));
      expect(snapshot.presentation.keys, isNot(contains('pending_download')));
    });

    test('side-effecting commands are never replayed', () {
      ProfileKey? profile;
      expect(
        isSideEffectingCommand(
          SurfaceCommand.navigate(
            sequence: 1,
            profileKey: profile,
            navigation: NavigationRequest(url: 'https://widgets.test/view'),
          ),
        ),
        isTrue,
      );
      expect(
        isSideEffectingCommand(
          SurfaceCommand.input(
            sequence: 1,
            input: InputEvent.pointer(kind: PointerKind.down, x: 1, y: 1),
          ),
        ),
        isTrue,
      );
      expect(
        isSideEffectingCommand(
          SurfaceCommand.script(
            sequence: 1,
            envelope: ScriptEnvelope(
              source: ScriptSource.app,
              origin: 'https://widgets.test',
              channel: 'c',
              requestId: 'r',
              value: 'v',
            ),
          ),
        ),
        isTrue,
      );
      for (final command in [
        SurfaceCommand.permission(
            sequence: 1, requestId: 'p', decision: PermissionDecision.deny),
        SurfaceCommand.popup(
            sequence: 1, requestId: 'p', action: PopupAction.deny),
        SurfaceCommand.download(
            sequence: 1, requestId: 'd', decision: const DenyDownload()),
        SurfaceCommand.clipboard(
            sequence: 1, requestId: 'c', decision: ClipboardDecision.deny),
        SurfaceCommand.upload(
            sequence: 1, requestId: 'u', decision: const DenyUpload()),
      ]) {
        expect(isSideEffectingCommand(command), isTrue,
            reason: '${command.runtimeType}');
      }
      expect(
        isSideEffectingCommand(
          SurfaceCommand.resize(
              sequence: 1, width: 800, height: 600, deviceScaleFactor: 1),
        ),
        isFalse,
      );
      expect(
        isSideEffectingCommand(
          SurfaceCommand.focus(sequence: 1, focused: true),
        ),
        isFalse,
      );
      // The lifecycle engine never replays either.
      final lifecycle = RuntimeLifecycle();
      expect(lifecycle.shouldReplayCommand(42), isFalse);
      final coordinator = SurfaceRecoveryCoordinator();
      expect(coordinator.shouldReplayCommand(42), isFalse);
    });

    test('unacknowledged fails and acknowledged becomes unknown', () {
      final lifecycle = RuntimeLifecycle();
      lifecycle.start(0);
      lifecycle.hostReady(0);
      lifecycle.registerSurface(const SurfaceId(1), _embeddedSpec('a'));
      final failed =
          lifecycle.beginCommand(const SurfaceId(1), sideEffecting: true);
      final unknown =
          lifecycle.beginCommand(const SurfaceId(1), sideEffecting: true);
      lifecycle.acknowledgeCommand(unknown.commandId);
      final events = lifecycle.hostLost(1);
      final outcomes = {
        for (final event in events)
          if (event.kind.type == RuntimeEventType.commandOutcome)
            event.kind.commandId!: event.kind.outcome,
      };
      expect(outcomes[failed.commandId], CommandOutcome.failed);
      expect(outcomes[unknown.commandId], CommandOutcome.unknown);
    });

    test('only latest presentation values are held during restart', () {
      final coordinator = SurfaceRecoveryCoordinator();
      coordinator.registerSurface(
        const SurfaceId(1),
        _embeddedSpec('account-a'),
      );
      coordinator.lifecycle.start(0);
      coordinator.lifecycle.hostReady(0);
      coordinator.lifecycle.reportFailure(
        FailureClass.hostCrash,
        1,
        message: 'host exited',
      );
      expect(coordinator.lifecycle.state, RuntimeState.restarting);
      final firstResize = ResizeCommand(
        sequence: 1,
        width: 800,
        height: 600,
        deviceScaleFactor: 1,
      );
      final secondResize = ResizeCommand(
        sequence: 2,
        width: 1280,
        height: 720,
        deviceScaleFactor: 2,
      );
      expect(
        coordinator.holdPresentationCommand(const SurfaceId(1), firstResize),
        isTrue,
      );
      expect(
        coordinator.holdPresentationCommand(const SurfaceId(1), secondResize),
        isTrue,
      );
      final flushed = coordinator.flushHeldPresentation(const SurfaceId(1));
      // Only the latest idempotent values are held: the second resize
      // overwrites the first, while side effects are never held.
      expect(flushed, hasLength(1));
      expect((flushed.single as ResizeCommand).width, 1280);
      expect(
        coordinator.holdPresentationCommand(
          const SurfaceId(1),
          NavigateCommand(
            sequence: 3,
            navigation: NavigationRequest(url: 'https://widgets.test/view'),
          ),
        ),
        isFalse,
      );
    });
  });

  group('renderer recovery is surface-scoped with GPU degrade and budgets', () {
    test('renderer failure recreates only that surface', () {
      final lifecycle = RuntimeLifecycle();
      lifecycle.start(0);
      lifecycle.hostReady(0);
      lifecycle.registerSurface(const SurfaceId(1), _embeddedSpec('a'));
      lifecycle.registerSurface(const SurfaceId(2), _embeddedSpec('a'));
      final epoch = lifecycle.runtimeEpoch;
      final events = lifecycle.reportSurfaceFailure(
        const SurfaceId(1),
        FailureClass.rendererCrash,
        1,
        message: 'renderer exited',
      );
      expect(lifecycle.runtimeEpoch, epoch);
      expect(
        events.any(
          (event) =>
              event.kind.type == RuntimeEventType.surfaceRecovering &&
              event.surfaceId == const SurfaceId(1),
        ),
        isTrue,
      );
      expect(
        events.any(
          (event) => event.surfaceId == const SurfaceId(2),
        ),
        isFalse,
      );
    });

    test('two renderer recoveries then terminal surface_failed', () {
      final lifecycle = RuntimeLifecycle();
      lifecycle.start(0);
      lifecycle.hostReady(0);
      lifecycle.registerSurface(const SurfaceId(1), _embeddedSpec('a'));
      lifecycle.reportSurfaceFailure(
        const SurfaceId(1),
        FailureClass.rendererCrash,
        1,
        message: 'first',
      );
      lifecycle.reportSurfaceFailure(
        const SurfaceId(1),
        FailureClass.rendererCrash,
        2,
        message: 'second',
      );
      final third = lifecycle.reportSurfaceFailure(
        const SurfaceId(1),
        FailureClass.rendererCrash,
        3,
        message: 'third',
      );
      expect(
        third.any(
          (event) => event.kind.type == RuntimeEventType.surfaceFailed,
        ),
        isTrue,
      );
    });

    test('GPU failure degrades to CPU and pins after two failures', () {
      final lifecycle = RuntimeLifecycle();
      lifecycle.start(0);
      lifecycle.hostReady(0);
      lifecycle.registerSurface(const SurfaceId(1), _embeddedSpec('a'));
      lifecycle.reportFailure(FailureClass.gpuCrash, 1, message: 'gpu');
      expect(lifecycle.state, RuntimeState.degraded);
      expect(lifecycle.gpuDisabled, isFalse);
      lifecycle.reportFailure(FailureClass.gpuCrash, 2, message: 'gpu');
      expect(lifecycle.gpuDisabled, isTrue);
      final coordinator = SurfaceRecoveryCoordinator();
      expect(coordinator.gpuDisabled, isFalse);
    });

    test('host retry budgets and terminal states are enforced', () {
      final lifecycle = RuntimeLifecycle();
      lifecycle.start(0);
      lifecycle.hostReady(0);
      lifecycle.registerSurface(const SurfaceId(1), _embeddedSpec('a'));
      for (var i = 0; i < 3; i++) {
        lifecycle.reportFailure(
          FailureClass.hostCrash,
          i + 1,
          message: 'host $i',
        );
        expect(lifecycle.state, RuntimeState.restarting);
      }
      lifecycle.reportFailure(
        FailureClass.hostCrash,
        4,
        message: 'over budget',
      );
      expect(lifecycle.state, RuntimeState.failed);
      // Manual retry starts one fresh epoch and one attempt.
      final epoch = lifecycle.runtimeEpoch;
      lifecycle.retry(5);
      expect(lifecycle.runtimeEpoch, epoch + 1);
      expect(lifecycle.state, RuntimeState.starting);
    });
  });

  group('clean close drains without orphaning', () {
    test('shutdown drain order is stable', () {
      expect(
        shutdownDrainOrder(
            [const SurfaceId(5), const SurfaceId(1), const SurfaceId(3)]),
        [const SurfaceId(1), const SurfaceId(3), const SurfaceId(5)],
      );
    });

    test('close always wins after host loss on every presenter', () async {
      final runtime = FakeBrowserRuntime();
      final embeddedId = await runtime.open(_embeddedSpec('account-a'));
      final embedded = LinuxEmbeddedPresenter(
        runtime: runtime,
        surfaceId: embeddedId,
        profileKey: ProfileKey('account-a'),
        compositor: LinuxCompositor.x11,
      );
      embedded.noteHostLost();
      expect(embedded.isReconnecting, isTrue);
      await embedded.close();
      expect(embedded.isClosed, isTrue);
      expect(embedded.isReconnecting, isFalse);

      final flatpakId = await runtime.open(_embeddedSpec('account-b'));
      final flatpak = FlatpakEmbeddedPresenter(
        runtime: runtime,
        surfaceId: flatpakId,
        profileKey: ProfileKey('account-b'),
        compositor: FlatpakCompositor.wayland,
      );
      flatpak.noteHostLost();
      expect(flatpak.isReconnecting, isTrue);
      await flatpak.close();
      expect(flatpak.isReconnecting, isFalse);
    });

    test('clean shutdown never schedules recovery', () {
      final lifecycle = RuntimeLifecycle();
      lifecycle.start(0);
      lifecycle.hostReady(0);
      lifecycle.beginShutdown();
      final events = lifecycle.reportFailure(
        FailureClass.hostCrash,
        1,
        message: 'exit during shutdown',
      );
      expect(
        events.any(
          (event) => event.kind.failure?.kind == FailureClass.cleanStop,
        ),
        isTrue,
      );
      expect(lifecycle.state, RuntimeState.stopping);
      lifecycle.finishShutdown(clean: true);
      expect(lifecycle.state, RuntimeState.stopped);
    });
  });
}
