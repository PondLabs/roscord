import 'package:commet/ui/atoms/lightbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_image_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<ImageProvider>> photos(WidgetTester tester, int count) async {
    final result = <ImageProvider>[];
    for (var i = 0; i < count; i++) {
      final image = (await tester
          .runAsync(() => createTestImage(width: 100, height: 100)))!;
      result.add(FixedImageProvider(image));
    }
    return result;
  }

  testWidgets('gallery arrows step through the images and wrap around',
      (tester) async {
    final images = await photos(tester, 3);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Lightbox(image: images.first, gallery: images),
      ),
    ));
    await tester.pump();

    Image shown() => tester.widget<Image>(find.byType(Image));

    expect(shown().image, same(images[0]));

    await tester.tap(find.byKey(const ValueKey('lightbox-next')));
    await tester.pump();
    expect(shown().image, same(images[1]));

    await tester.tap(find.byKey(const ValueKey('lightbox-previous')));
    await tester.pump();
    expect(shown().image, same(images[0]));

    await tester.tap(find.byKey(const ValueKey('lightbox-previous')));
    await tester.pump();
    expect(shown().image, same(images[2]),
        reason: 'stepping back from the first image wraps to the last');
  });

  testWidgets('a single image has a close button but no arrows',
      (tester) async {
    final images = await photos(tester, 1);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Lightbox(image: images.first)),
    ));
    await tester.pump();

    expect(find.byKey(const ValueKey('lightbox-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('lightbox-previous')), findsNothing);
    expect(find.byKey(const ValueKey('lightbox-next')), findsNothing);
  });

  testWidgets('the close button dismisses the modal', (tester) async {
    final images = await photos(tester, 2);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Lightbox.show(
              context,
              image: images.first,
              gallery: images,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(Lightbox), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('lightbox-close')));
    await tester.pumpAndSettle();
    expect(find.byType(Lightbox), findsNothing);
  });
}
