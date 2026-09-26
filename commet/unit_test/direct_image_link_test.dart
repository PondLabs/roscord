import 'package:commet/client/components/url_preview/direct_image_link.dart';
import 'package:commet/client/components/url_preview/url_preview_component.dart';
import 'package:commet/client/matrix/components/url_preview/matrix_url_preview_component.dart';
import 'package:commet/client/matrix/matrix_client.dart';
import 'package:commet/client/room.dart';
import 'package:commet/client/timeline.dart';
import 'package:commet/client/timeline_events/timeline_event_message.dart';
import 'package:commet/ui/atoms/lightbox.dart';
import 'package:commet/ui/molecules/url_preview_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tiamat/config/style/theme_extensions.dart';

import 'test_image_provider.dart';

class _FakeMatrixClient implements MatrixClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRoom implements Room {
  _FakeRoom({required this.isE2EE});

  @override
  final bool isE2EE;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTimeline extends Timeline {
  _FakeTimeline(Room room) {
    this.room = room;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeMessage implements TimelineEventMessage {
  _FakeMessage(this.link);

  final Uri link;

  @override
  List<Uri>? getLinks({Timeline? timeline}) => [link];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An image link that answers with something that isn't an image, like the
/// 403 page Akamai serves to fetchers it doesn't like.
class _BrokenImageProvider extends ImageProvider<_BrokenImageProvider> {
  @override
  Future<_BrokenImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_BrokenImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
      _BrokenImageProvider key, ImageDecoderCallback decode) {
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.error(Exception('403 Forbidden')),
    );
  }
}

Widget _testApp(Widget child) => MaterialApp(
      theme: ThemeData.light().copyWith(
        extensions: const [ThemeSettings()],
      ),
      home: Scaffold(body: Center(child: child)),
    );

final _hornetUri = Uri.parse(
    'https://powersports.honda.com/motorcycle/standard/cb1000-hornet-sp/2026/'
    '-/media/products/family/cb1000-hornet-sp/trim-hero/gallery/'
    'cb1000-hornet-sp/2026/matte-black-metallic/'
    '2026-cb1000-hornet-sp-matte_black_metallic-gallery-02.png');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('an image link', () {
    final cases = {
      _hornetUri.toString(): true,
      'https://example.com/a/photo.JPG': true,
      'https://example.com/photo.jpeg?width=800': true,
      'https://example.com/cat.gif#loop': true,
      'https://example.com/sticker.webp': true,
      'https://example.com/scan.bmp': true,
      'https://example.com/page': false,
      'https://example.com/page.html': false,
      'https://example.com/images.png/view': false,
      'https://example.com/': false,
      'https://example.com/clip.mp4': false,
      'http://example.com/photo.png': false,
      'mxc://example.com/photo.png': false,
    };

    for (final MapEntry(key: link, value: isImage) in cases.entries) {
      test('${isImage ? 'is' : 'is not'} $link', () {
        expect(DirectImageLink.matches(Uri.parse(link)), isImage);
      });
    }
  });

  group('MatrixUrlPreviewComponent', () {
    test(
        'previews an image link in an encrypted room without the homeserver, '
        'loading the image itself', () async {
      final component = MatrixUrlPreviewComponent(_FakeMatrixClient());
      final timeline = _FakeTimeline(_FakeRoom(isE2EE: true));

      final data =
          await component.getPreview(timeline, _FakeMessage(_hornetUri));

      expect(data?.type, UrlDestinationType.image);
      final image = data!.image as NetworkImage;
      expect(image.url, _hornetUri.toString());
      expect(image.webHtmlElementStrategy, WebHtmlElementStrategy.fallback,
          reason: 'most image hosts send no CORS headers, so web needs <img>');
    });

    test('asks for image link previews when the homeserver has none', () {
      final component = MatrixUrlPreviewComponent(_FakeMatrixClient())
        ..serverSupportsUrlPreview = false;
      final timeline = _FakeTimeline(_FakeRoom(isE2EE: false));

      expect(
          component.shouldGetPreviewDataForTimelineEvent(
              timeline, _FakeMessage(_hornetUri)),
          isTrue);
      expect(
          component.shouldGetPreviewDataForTimelineEvent(
              timeline, _FakeMessage(Uri.parse('https://example.com/page'))),
          isFalse);
    });
  });

  group('UrlPreviewWidget with an image link', () {
    Future<UrlPreviewData> photoPreview(WidgetTester tester) async {
      final photo = (await tester
          .runAsync(() => createTestImage(width: 1920, height: 1080)))!;
      return UrlPreviewData(
        _hornetUri,
        type: UrlDestinationType.image,
        image: FixedImageProvider(photo),
      );
    }

    testWidgets('shows the image alone, scaled down to media size',
        (tester) async {
      await tester
          .pumpWidget(_testApp(UrlPreviewWidget(await photoPreview(tester))));
      await tester.pump();

      expect(find.byKey(const ValueKey('url-preview-card')), findsNothing,
          reason: 'there is nothing to put in a card beside the image');
      expect(find.text(_hornetUri.toString()), findsNothing,
          reason: 'the message above already shows the link');
      expect(tester.getSize(find.byType(Image)), const Size(480, 270));
    });

    testWidgets('opens the image in the lightbox when tapped', (tester) async {
      await tester
          .pumpWidget(_testApp(UrlPreviewWidget(await photoPreview(tester))));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('url-preview-image')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.byType(Lightbox), findsOneWidget);
    });

    testWidgets('leaves nothing on screen when the link is not an image',
        (tester) async {
      final preview = UrlPreviewData(
        _hornetUri,
        type: UrlDestinationType.image,
        image: _BrokenImageProvider(),
      );

      await tester.pumpWidget(_testApp(UrlPreviewWidget(preview)));
      await tester.pump();
      await tester.pump();

      expect(tester.getSize(find.byType(UrlPreviewWidget)), Size.zero);
    });
  });
}
