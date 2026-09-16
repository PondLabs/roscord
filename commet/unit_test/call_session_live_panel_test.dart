import 'dart:async';

import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/client/components/voip/voip_stream.dart';
import 'package:commet/ui/molecules/call_session_live_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiamat/config/style/theme_extensions.dart';

class FakeVoipSession implements VoipSession {
  @override
  bool isSharingScreen = false;

  @override
  bool isCameraEnabled = false;

  @override
  final List<VoipStream> streams = [];

  final StreamController<void> _stateChanged = StreamController.broadcast();

  @override
  Stream<void> get onStateChanged => _stateChanged.stream;

  int stopScreenshareCalls = 0;
  int stopCameraCalls = 0;

  void addOutgoing(VoipStreamType type) {
    streams.add(FakeVoipStream(type, VoipStreamDirection.outgoing));
    if (type == VoipStreamType.screenshare) isSharingScreen = true;
    if (type == VoipStreamType.video) isCameraEnabled = true;
    _stateChanged.add(null);
  }

  void removeOutgoing(VoipStreamType type) {
    streams.removeWhere(
        (s) => s.type == type && s.direction == VoipStreamDirection.outgoing);
    if (type == VoipStreamType.screenshare) isSharingScreen = false;
    if (type == VoipStreamType.video) isCameraEnabled = false;
    _stateChanged.add(null);
  }

  @override
  Future<void> stopScreenshare() async {
    stopScreenshareCalls++;
    removeOutgoing(VoipStreamType.screenshare);
  }

  @override
  Future<void> stopCamera() async {
    stopCameraCalls++;
    removeOutgoing(VoipStreamType.video);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeVoipStream implements VoipStream {
  FakeVoipStream(this.type, this.direction);

  @override
  final VoipStreamType type;

  @override
  final VoipStreamDirection direction;

  @override
  String get streamId => "${direction.name}_${type.name}";

  @override
  Widget? buildVideoRenderer(BoxFit fit, Key key) =>
      ColoredBox(key: ValueKey("renderer_$streamId"), color: Colors.black);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _testApp(Widget child) => MaterialApp(
      theme: ThemeData.light().copyWith(
        extensions: const [ThemeSettings()],
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          // Same width as the sidebar the panel lives in.
          child: SizedBox(width: 240, child: child),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets("renders nothing while not sharing anything", (tester) async {
    final session = FakeVoipSession();
    await tester.pumpWidget(_testApp(CallSessionLivePanel(session: session)));

    expect(find.text("LIVE"), findsNothing);
    expect(find.byKey(CallSessionLivePanel.previewKey), findsNothing);
  });

  testWidgets("shows LIVE indicator and screen preview while sharing screen",
      (tester) async {
    final session = FakeVoipSession();
    session.addOutgoing(VoipStreamType.screenshare);

    await tester.pumpWidget(_testApp(CallSessionLivePanel(session: session)));

    expect(find.text("LIVE"), findsOneWidget);
    expect(find.text("Screen"), findsOneWidget);
    expect(find.byKey(const ValueKey("renderer_outgoing_screenshare")),
        findsOneWidget);
    expect(find.byKey(CallSessionLivePanel.stopScreenshareKey), findsOneWidget);
    expect(find.byKey(CallSessionLivePanel.stopCameraKey), findsNothing);
  });

  testWidgets("shows camera preview and its stop button turns the camera off",
      (tester) async {
    final session = FakeVoipSession();
    session.addOutgoing(VoipStreamType.video);

    await tester.pumpWidget(_testApp(CallSessionLivePanel(session: session)));

    expect(find.text("LIVE"), findsOneWidget);
    expect(find.text("Camera"), findsOneWidget);
    expect(
        find.byKey(const ValueKey("renderer_outgoing_video")), findsOneWidget);
    expect(find.byKey(CallSessionLivePanel.stopScreenshareKey), findsNothing);

    await tester.tap(find.byKey(CallSessionLivePanel.stopCameraKey));
    await tester.pump();

    expect(session.stopCameraCalls, 1);
    expect(find.text("LIVE"), findsNothing);
    expect(find.byKey(CallSessionLivePanel.previewKey), findsNothing);
  });

  testWidgets(
      "screen and camera together: both stop buttons, switchable preview",
      (tester) async {
    final session = FakeVoipSession();
    session.addOutgoing(VoipStreamType.screenshare);
    session.addOutgoing(VoipStreamType.video);

    await tester.pumpWidget(_testApp(CallSessionLivePanel(session: session)));

    expect(find.text("LIVE"), findsOneWidget);
    expect(find.byKey(CallSessionLivePanel.stopScreenshareKey), findsOneWidget);
    expect(find.byKey(CallSessionLivePanel.stopCameraKey), findsOneWidget);
    // Screen is shown first; the camera is one tap away.
    expect(find.byKey(const ValueKey("renderer_outgoing_screenshare")),
        findsOneWidget);
    expect(find.byKey(const ValueKey("renderer_outgoing_video")), findsNothing);

    await tester.tap(find.byKey(CallSessionLivePanel.showCameraKey));
    await tester.pump();

    expect(
        find.byKey(const ValueKey("renderer_outgoing_video")), findsOneWidget);
    expect(find.byKey(const ValueKey("renderer_outgoing_screenshare")),
        findsNothing);

    // Stopping the screen share leaves the camera preview up.
    await tester.tap(find.byKey(CallSessionLivePanel.stopScreenshareKey));
    await tester.pump();

    expect(session.stopScreenshareCalls, 1);
    expect(find.text("Camera"), findsOneWidget);
    expect(
        find.byKey(const ValueKey("renderer_outgoing_video")), findsOneWidget);
    expect(find.byKey(CallSessionLivePanel.stopScreenshareKey), findsNothing);
  });

  testWidgets("hides when the capture ends outside the panel (OS / picker)",
      (tester) async {
    final session = FakeVoipSession();
    session.addOutgoing(VoipStreamType.screenshare);
    await tester.pumpWidget(_testApp(CallSessionLivePanel(session: session)));
    expect(find.text("LIVE"), findsOneWidget);

    // Only onStateChanged fires; nothing was tapped in the panel.
    session.removeOutgoing(VoipStreamType.screenshare);
    await tester.pump();

    expect(find.text("LIVE"), findsNothing);
    expect(find.byKey(CallSessionLivePanel.previewKey), findsNothing);
  });

  testWidgets("tapping the preview opens the voice channel", (tester) async {
    final session = FakeVoipSession();
    session.addOutgoing(VoipStreamType.screenshare);
    var opened = 0;
    await tester.pumpWidget(_testApp(
        CallSessionLivePanel(session: session, onOpen: () => opened++)));

    await tester.tap(find.byKey(CallSessionLivePanel.previewKey));
    expect(opened, 1);
  });

  testWidgets("fits the sidebar width without overflowing", (tester) async {
    final session = FakeVoipSession();
    session.addOutgoing(VoipStreamType.screenshare);
    session.addOutgoing(VoipStreamType.video);
    await tester.pumpWidget(_testApp(CallSessionLivePanel(session: session)));
    // Any RenderFlex overflow is reported as a test error by the binding.
    expect(tester.takeException(), isNull);
  });
}
