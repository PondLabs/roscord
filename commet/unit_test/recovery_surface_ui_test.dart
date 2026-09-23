import 'package:commet/browser_runtime.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('reconnecting overlay is an accessible live region',
      (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: ReconnectingBrowserOverlay(),
      ),
    );
    expect(find.text('Reconnecting browser…'), findsOneWidget);
    final semantics = tester.getSemantics(find.byType(Semantics).first);
    expect(semantics.label, contains('Reconnecting browser'));
    // Live region so screen readers announce host-restart state changes.
    expect(semantics.flagsCollection.isLiveRegion, isTrue);
  });

  testWidgets('crashed-surface card exposes retry, close, and reporting',
      (tester) async {
    var retried = false;
    var closed = false;
    var reported = false;
    var copied = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CrashedSurfaceCard(
          title: 'This embedded page crashed. Retry',
          diagnosticId: 'd-3-7',
          onRetry: () => retried = true,
          onClose: () => closed = true,
          onReport: () => reported = true,
          onCopyDiagnosticId: () => copied = true,
        ),
      ),
    );
    expect(find.text('This embedded page crashed. Retry'), findsOneWidget);
    expect(find.text('Diagnostic d-3-7'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(find.text('Report diagnostics'), findsOneWidget);
    expect(find.text('Copy diagnostic ID'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.tap(find.text('Close'));
    await tester.tap(find.text('Report diagnostics'));
    await tester.tap(find.text('Copy diagnostic ID'));
    expect(retried, isTrue);
    expect(closed, isTrue);
    expect(reported, isTrue);
    expect(copied, isTrue);

    // Keyboard-focusable actions expose button semantics with hints.
    for (final label in [
      'Retry',
      'Close',
      'Report diagnostics',
      'Copy diagnostic ID'
    ]) {
      expect(find.bySemanticsLabel(label), findsWidgets, reason: label);
    }
  });

  testWidgets('graphics-unavailable uses the fixed contract string',
      (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CrashedSurfaceCard(
          title: 'Graphics unavailable. Retry',
          diagnosticId: 'd-1-2',
          onRetry: () {},
          onClose: () {},
          onReport: () {},
          onCopyDiagnosticId: () {},
        ),
      ),
    );
    expect(find.text('Graphics unavailable. Retry'), findsOneWidget);
  });

  testWidgets('runtime-unavailable card offers retry browser', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: RuntimeUnavailableCard(
          diagnosticId: 'd-5-1',
          onRetryBrowser: () => retried = true,
        ),
      ),
    );
    expect(
      find.text('Embedded browser unavailable. Retry browser'),
      findsOneWidget,
    );
    expect(find.text('Diagnostic d-5-1'), findsOneWidget);
    await tester.tap(find.text('Retry browser'));
    expect(retried, isTrue);
  });

  testWidgets('recovery cards never show raw internals', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CrashedSurfaceCard(
          title: 'This embedded page crashed. Retry',
          diagnosticId: 'd-2-3',
          onRetry: () {},
          onClose: () {},
          onReport: () {},
          onCopyDiagnosticId: () {},
        ),
      ),
    );
    final text = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data ?? '')
        .join('\n');
    for (final forbidden in [
      r'C:\',
      'https://',
      'TS_PROCESS_CRASHED',
      'profile-',
      'account-record',
      'cookie',
      'device-',
    ]) {
      expect(text, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}
