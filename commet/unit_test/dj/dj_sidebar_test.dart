// The booth outside the call view: the DJ's row in the sidebar's voice list,
// the now playing pill's strip, and the sidebar asking the call view to open
// the booth.
import 'dart:async';

import 'package:commet/client/components/dj/dj_models.dart';
import 'package:commet/client/components/dj/dj_session.dart';
import 'package:commet/client/components/voip/voip_session.dart';
import 'package:commet/client/matrix/components/dj/dj_booths.dart';
import 'package:commet/main.dart';
import 'package:commet/ui/organisms/dj/dj_booth_panel.dart';
import 'package:commet/ui/organisms/dj/dj_member_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tiamat/config/style/theme_extensions.dart';

import 'dj_fakes.dart';

class _Session implements VoipSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DjSession _session(FakeCall call, String identity) => DjSession(
      transport: call.join(identity),
      caps: const DjCaps(canDj: true, platform: 'linux'),
      selfUserId: djUserIdOf(identity),
      engineFactory: () => FakeEngine(identity),
      resolver: FakeResolver(),
      tickInterval: const Duration(seconds: 2),
      pollInterval: const Duration(milliseconds: 250),
    )..start();

Widget _app(Widget child) => MaterialApp(
      theme: ThemeData(platform: TargetPlatform.linux)
          .copyWith(extensions: const [ThemeSettings()]),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 240, child: child),
        ),
      ),
    );

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump();
  }
}

Future<void> _teardown(WidgetTester tester, List<DjSession> sessions) async {
  await tester.pumpWidget(const SizedBox());
  for (final s in sessions) {
    unawaited(s.dispose());
  }
  await _drain(tester);
}

String _nameOf(String userId) => userId.split(':').first.substring(1);

void main() {
  setUp(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    await preferences.init();
  });

  testWidgets('the sidebar row shows who DJs and what plays, and opens',
      (tester) async {
    final call = FakeCall();
    final dj = _session(call, '@dj:x:D1');
    final listener = _session(call, '@l:x:L1');
    var taps = 0;

    await tester.pumpWidget(_app(Column(children: [
      DjSidebarRow(dj: listener, nameOf: _nameOf, onTap: () => taps++),
    ])));
    await _drain(tester);
    // Nobody DJs: no row.
    expect(find.byType(InkWell), findsNothing);

    await dj.becomeDj();
    await _drain(tester);
    dj.addTracks([track('s1')]);
    await _drain(tester);
    expect(find.text('DJ · dj'), findsOneWidget);
    expect(find.textContaining(listener.current!.title), findsOneWidget);

    await tester.tap(find.byType(InkWell));
    expect(taps, 1);

    await dj.stopDjing();
    await _drain(tester);
    expect(find.text('DJ · dj'), findsNothing);
    await _teardown(tester, [dj, listener]);
  });

  testWidgets('the now playing pill takes no room while nobody DJs',
      (tester) async {
    final call = FakeCall();
    final dj = _session(call, '@dj:x:D1');
    const padding = EdgeInsets.fromLTRB(8, 8, 8, 4);

    await tester.pumpWidget(_app(DjNowPlayingPill(
        dj: dj, padding: padding, onTap: () {}, key: const Key('pill'))));
    await _drain(tester);
    expect(tester.getSize(find.byKey(const Key('pill'))).height, 0);

    await dj.becomeDj();
    await _drain(tester);
    expect(tester.getSize(find.byKey(const Key('pill'))).height,
        greaterThan(padding.vertical));
    await _teardown(tester, [dj]);
  });

  test('a request for the booth panel waits for the call view', () {
    final session = _Session();
    final other = _Session();
    final seen = <VoipSession>[];
    final sub = DjBooths.onPanelRequested.listen(seen.add);

    DjBooths.showPanel(session);
    expect(DjBooths.takePanelRequest(other), isFalse);
    expect(DjBooths.takePanelRequest(session), isTrue);
    // Taken once.
    expect(DjBooths.takePanelRequest(session), isFalse);
    sub.cancel();
  });
}
