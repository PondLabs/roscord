import 'package:commet/diagnostic/benchmark_values.dart';
import 'package:commet/ui/pages/developer/benchmarks/benchmark_utils.dart';
import 'package:commet/ui/pages/developer/benchmarks/timeline_viewer_benchmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tiamat/config/style/theme_dark.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Timeline Viewer Test', (tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(MaterialApp(
      theme: ThemeDark.theme,
      home: const Scaffold(
        body: BenchmarkTimelineViewer(),
      ),
    ));

    // The viewer builds its timeline asynchronously, so wait for the list
    // rather than guessing at how long that takes: a fixed pump reports
    // "Bad state: No element" from inside scrollUntilVisible, which says
    // nothing about what was actually missing.
    final listFinder = find.byType(Scrollable);
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 100 && listFinder.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(listFinder, findsOneWidget,
        reason: 'the timeline viewer never drew its list');

    final itemFinder = find.text(finalEventMessage);

    var reportKey = 'TimelineViewer Scrolling';

    await binding.traceAction(
      () async {
        // Scroll until the item to be found appears.
        await tester.scrollUntilVisible(
          itemFinder,
          50.0,
          maxScrolls: 10000,
          scrollable: listFinder,
        );
      },
      reportKey: reportKey,
    );

    binding.reportData?[reportKey]["extra_values"] = [
      {
        "name": "$reportKey - Timeline Event Build Count",
        "value": BenchmarkValues.numTimelineEventsBuilt,
        "unit": "Builds",
      },
      {
        "name": "$reportKey - Timeline Event Message Body Build Count",
        "value": BenchmarkValues.numTimelineMessageBodyBuilt,
        "unit": "Builds",
      },
      {
        "name": "$reportKey - Timeline Event Message Reply Body Build Count",
        "value": BenchmarkValues.numTimelineReplyBodyBuilt,
        "unit": "Builds",
      },
      {
        "name": "$reportKey - Timeline Event Message Url Preview Build Count",
        "value": BenchmarkValues.numTimelineUrlPreviewBuilt,
        "unit": "Builds",
      }
    ];
  });
}
