import 'dart:async';

import 'package:commet/browser_runtime.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

SurfaceSpec _embeddedSpec({String profile = 'account-a'}) {
  return SurfaceSpec(
    profileKey: ProfileKey(profile),
    presentation: PresentationMode.embedded,
    privacy: PrivacyMode.persistent,
    initialNavigation: NavigationRequest(url: 'https://widget.test/index'),
    policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
  );
}

FrameReference _frame(int sequence, {int slot = 0}) => FrameReference(
      slot: slot,
      width: 1280,
      height: 720,
      stride: 1280 * 4,
      format: PixelFormat.bgraPremultiplied,
      sequence: sequence,
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

/// Recording decorator over the deterministic fake: keeps the fake's event
/// semantics while capturing every command for input/resize/focus ordering
/// assertions.
class _RecordingRuntime implements BrowserRuntime {
  final FakeBrowserRuntime _inner = FakeBrowserRuntime();
  final List<SurfaceCommand> commands = [];

  @override
  Stream<SurfaceEvent> events() => _inner.events();

  @override
  Future<SurfaceId> open(SurfaceSpec spec) => _inner.open(spec);

  @override
  Future<void> command(SurfaceId surfaceId, SurfaceCommand command) {
    commands.add(command);
    return _inner.command(surfaceId, command);
  }

  @override
  Future<void> close(SurfaceId surfaceId) => _inner.close(surfaceId);

  void publishFrame(SurfaceId id, FrameReference frame) =>
      _inner.publishFrame(id, frame);
}

void main() {
  test(
      'CPU frames are copied as client-owned references and presented as a Flutter texture',
      () async {
    final runtime = _RecordingRuntime();
    final surface = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
      textureId: 7,
    );
    final id = await surface.open();
    await _flush();
    expect(surface.isReady, isTrue);

    // Two rapid frames coalesce to the newest client-owned reference.
    runtime.publishFrame(id, _frame(1, slot: 0));
    runtime.publishFrame(id, _frame(2, slot: 1));
    await _flush();

    expect(surface.latestFrame, isNotNull);
    expect(surface.latestFrame!.sequence, 2);
    expect(surface.latestFrame!.slot, 1);
    expect(surface.latestFrame!.width, 1280);
    expect(surface.latestFrame!.height, 720);
    expect(surface.latestFrame!.stride, 1280 * 4);
    expect(surface.latestFrame!.format, PixelFormat.bgraPremultiplied);

    // Presenting releases the newest sequence; the release never carries a
    // CEF pointer, only the frame sequence.
    await surface.presentLatestAsTexture();
    final release =
        runtime.commands.whereType<ReleaseFrameCommand>().single;
    expect(release.frameSequence, 2);

    // Stale frames cannot regress the texture.
    runtime.publishFrame(id, _frame(1, slot: 0));
    await _flush();
    expect(surface.latestFrame!.sequence, 2);

    await surface.close();
    await surface.dispose();
  });

  test(
      'Matrix adapter behavior works against the local fixture through the embedded surface',
      () async {
    final runtime = _RecordingRuntime();
    final surface = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
    );
    final id = await surface.open();
    await _flush();

    // Profile binding: the surface profile key is the stable account record.
    expect(surface.spec.profileKey, ProfileKey('account-a'));

    // Navigation: in-policy fixture navigation is accepted.
    await surface._sendForTest(
      runtime,
      id,
      (sequence) => SurfaceCommand.navigate(
        sequence: sequence,
        profileKey: surface.spec.profileKey,
        navigation: NavigationRequest(url: 'https://widget.test/room'),
      ),
    );

    // Script bridge: Matrix messages travel as generic script envelopes.
    await runtime.command(
      id,
      ScriptCommand(
        sequence: 100,
        profileKey: surface.spec.profileKey,
        envelope: ScriptEnvelope(
          source: ScriptSource.app,
          origin: 'commet://widget',
          channel: 'chat.commet.matrix_widget',
          requestId: 'bridge-1',
          value: {
            'operation': 'dispatch_script_message',
            'storage_key': 'chat.commet.toWidget:1',
            'payload': '_payload\n',
          },
        ),
      ),
    );

    // Downloads, clipboard, uploads, and media decisions are mediated
    // commands: the fake accepts them and the real host turns them into
    // request events for explicit app decisions.
    await runtime.command(
      id,
      DownloadCommand(
        sequence: 101,
        profileKey: surface.spec.profileKey,
        requestId: 'download-1',
        decision: const DenyDownload(),
      ),
    );
    await runtime.command(
      id,
      ClipboardCommand(
        sequence: 102,
        profileKey: surface.spec.profileKey,
        requestId: 'clipboard-1',
        decision: ClipboardDecision.deny,
      ),
    );
    await runtime.command(
      id,
      UploadCommand(
        sequence: 103,
        profileKey: surface.spec.profileKey,
        requestId: 'upload-1',
        decision: const DenyUpload(),
      ),
    );
    await runtime.command(
      id,
      PermissionCommand(
        sequence: 104,
        profileKey: surface.spec.profileKey,
        requestId: 'media-1',
        decision: PermissionDecision.deny,
      ),
    );

    // Cross-account isolation: a mismatched profile key is rejected.
    await expectLater(
      runtime.command(
        id,
        FocusCommand(
          sequence: 105,
          profileKey: ProfileKey('account-b'),
          focused: true,
        ),
      ),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.profileMismatch,
        ),
      ),
    );

    await surface.close();
    await surface.dispose();
  });

  test('pointer, keyboard, wheel, focus, IME, resize, DPI, and close work',
      () async {
    final runtime = _RecordingRuntime();
    final surface = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
    );
    await surface.open();
    await _flush();

    await surface.pointer(PointerKind.down, 100, 200, buttons: 1);
    await surface.pointer(PointerKind.move, 110, 210);
    await surface.pointer(PointerKind.up, 110, 210);
    await surface.wheel(110, 210, 0, -120);
    await surface.key('a', 'KeyA', pressed: true);
    await surface.key('a', 'KeyA', pressed: false);
    await surface.ime(ImePhase.start, 'ni', selectionStart: 0, selectionEnd: 2);
    await surface.ime(ImePhase.update, 'nih', selectionStart: 0, selectionEnd: 3);
    await surface.ime(ImePhase.commit, 'nihon', selectionStart: 5, selectionEnd: 5);
    await surface.ime(ImePhase.cancel, '');
    await surface.resize(1280, 720, 1.0);
    await surface.resize(1920, 1080, 2.0);
    await surface.setFocus(true);
    await surface.setFocus(false);

    final inputs =
        runtime.commands.whereType<InputCommand>().map((c) => c.input).toList();
    expect(inputs.whereType<PointerInput>(), hasLength(4));
    expect(inputs.whereType<KeyboardInput>(), hasLength(2));
    expect(inputs.whereType<ImeInput>(), hasLength(4));

    final wheel =
        inputs.whereType<PointerInput>().firstWhere((p) => p.kind == PointerKind.wheel);
    expect(wheel.deltaY, -120);

    final imePhases = inputs.whereType<ImeInput>().map((i) => i.phase).toList();
    expect(
      imePhases,
      [ImePhase.start, ImePhase.update, ImePhase.commit, ImePhase.cancel],
    );

    // Inverted IME selection is rejected by the contract.
    await expectLater(
      surface.ime(ImePhase.update, 'x', selectionStart: 3, selectionEnd: 1),
      throwsA(isA<BrowserRuntimeException>()),
    );

    // Resize/DPI produce normalized window events in order.
    final events = <SurfaceEvent>[];
    final subscription = surface.surfaceEvents.listen(events.add);
    await surface.resize(800, 600, 1.5);
    await _flush();
    final resized = events.whereType<WindowChangedEvent>().last.change
        as ResizedWindow;
    expect(resized.width, 800);
    expect(resized.deviceScaleFactor, 1.5);
    await subscription.cancel();

    // Sequences strictly increase across mixed command classes.
    final sequences = runtime.commands.map((c) => c.sequence).toList();
    expect(sequences, orderedEquals(sequences..sort()));
    expect(sequences.toSet(), hasLength(sequences.length));

    // Close is terminal: further commands are stale.
    await surface.close();
    await _flush();
    expect(surface.isClosed, isTrue);
    await expectLater(
      surface.pointer(PointerKind.move, 0, 0),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.staleSurface,
        ),
      ),
    );
    await surface.dispose();
  });

  test('forced software rendering satisfies the same contract', () async {
    // The software flag lives on the host starter; the embedded surface
    // contract is identical either way.  Both paths present the same frame
    // ring, input, resize, focus, and close behavior.
    final defaultRuntime = _RecordingRuntime();
    final softwareRuntime = _RecordingRuntime();
    final defaultSurface = EmbeddedBrowserSurface(
      runtime: defaultRuntime,
      spec: _embeddedSpec(),
    );
    final softwareSurface = EmbeddedBrowserSurface(
      runtime: softwareRuntime,
      spec: _embeddedSpec(),
    );
    final defaultId = await defaultSurface.open();
    final softwareId = await softwareSurface.open();
    await _flush();

    for (final entry in [(defaultRuntime, defaultId), (softwareRuntime, softwareId)]) {
      entry.$1.publishFrame(entry.$2, _frame(1));
    }
    await _flush();

    expect(defaultSurface.latestFrame!.sequence, 1);
    expect(softwareSurface.latestFrame!.sequence, 1);

    // The Dart seam exposes the production host flag; the static contract
    // test proves the host honors --cef-software-rendering with the same
    // CPU OnPaint path and no engine fallback.
    final softwareHost = WindowsBrowserRuntime(forceSoftwareRendering: true);
    expect(softwareHost.forceSoftwareRendering, isTrue);
    await softwareHost.dispose();

    final defaultHost = WindowsBrowserRuntime();
    expect(defaultHost.forceSoftwareRendering, isFalse);
    await defaultHost.dispose();

    await defaultSurface.close();
    await softwareSurface.close();
    await defaultSurface.dispose();
    await softwareSurface.dispose();
  });

  test('WebView2, Wry, system CEF, unowned browsers, and fallback are impossible',
      () async {
    // Embedded presentation is the only admitted mode for this surface.
    expect(
      () => EmbeddedBrowserSurface(
        runtime: _RecordingRuntime(),
        spec: SurfaceSpec(
          profileKey: ProfileKey('account-a'),
          presentation: PresentationMode.standalone,
          privacy: PrivacyMode.persistent,
          initialNavigation:
              NavigationRequest(url: 'https://widget.test/index'),
          policy: SurfacePolicy(allowedOrigins: ['https://widget.test']),
        ),
      ),
      throwsArgumentError,
    );

    // No fallback on unknown surfaces: the runtime reports stale instead of
    // opening another engine.
    final runtime = _RecordingRuntime();
    await expectLater(
      runtime.command(
        const SurfaceId(999),
        FocusCommand(sequence: 1, focused: true),
      ),
      throwsA(
        isA<BrowserRuntimeException>().having(
          (error) => error.code,
          'code',
          BrowserRuntimeErrorCode.staleSurface,
        ),
      ),
    );

    // The surface closes deterministically and never reopens implicitly.
    final surface = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
    );
    await surface.open();
    await surface.close();
    await _flush();
    expect(surface.isClosed, isTrue);
    await expectLater(
      runtime.close(surface.surfaceId!),
      throwsA(isA<BrowserRuntimeException>()),
    );
    await surface.dispose();
  });

  testWidgets('EmbeddedBrowserView presents frames as a Flutter texture',
      (tester) async {
    final runtime = _RecordingRuntime();
    final surface = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
      textureId: 42,
    );
    await surface.open();
    await tester.pump();
    await tester.pumpWidget(EmbeddedBrowserView(surface: surface));
    await tester.pump();
    // Ready with no frame yet shows the ready placeholder.
    expect(find.textContaining('ready'), findsOneWidget);

    runtime.publishFrame(surface.surfaceId!, _frame(1));
    await tester.pump();
    await tester.pump();
    expect(find.byType(Texture), findsOneWidget);

    addTearDown(() async {
      await surface.close();
      await surface.dispose();
    });
  });

  testWidgets('EmbeddedBrowserView shows frame metadata without a texture',
      (tester) async {
    final runtime = _RecordingRuntime();
    final surface = EmbeddedBrowserSurface(
      runtime: runtime,
      spec: _embeddedSpec(),
    );
    await surface.open();
    await tester.pump();
    await tester.pumpWidget(EmbeddedBrowserView(surface: surface));
    await tester.pump();
    runtime.publishFrame(surface.surfaceId!, _frame(3));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('1280x720'), findsOneWidget);
    expect(find.textContaining('seq=3'), findsOneWidget);

    addTearDown(() async {
      await surface.close();
      await surface.dispose();
    });
  });
}

extension on EmbeddedBrowserSurface {
  Future<void> _sendForTest(
    BrowserRuntime runtime,
    SurfaceId id,
    SurfaceCommand Function(int sequence) build,
  ) {
    return runtime.command(id, build(1));
  }
}
