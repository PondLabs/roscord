import 'dart:ui' as ui;

import 'package:commet/client/components/url_preview/url_preview_component.dart';
import 'package:commet/client/components/video_embed/providers/twitter_provider.dart';
import 'package:commet/ui/molecules/url_preview_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tiamat/config/style/theme_extensions.dart';

import 'test_image_provider.dart';

Widget _testApp(Widget child) => MaterialApp(
      theme: ThemeData.light().copyWith(
        extensions: const [ThemeSettings()],
      ),
      home: Scaffold(body: Center(child: child)),
    );

final _republiqueUri =
    Uri.parse('https://x.com/republiqueBRA/status/2101410094642532486');

final _censoredMenUri =
    Uri.parse('https://x.com/CensoredMen/status/1762120865213231205');

const _censoredMenFixture = '''
{"tweet":{"text":"Jacob Rothschild has died.","author":{"name":"Censored Men","screen_name":"CensoredMen"},
"media":{"photos":[
{"type":"photo","id":"1762120856287793152","url":"https://pbs.twimg.com/media/GHRPlSpXUAASoAE.jpg?name=orig","width":1290,"height":720},
{"type":"photo","id":"1762120856287821824","url":"https://pbs.twimg.com/media/GHRPlSpXwAAHv9d.jpg?name=orig","width":800,"height":600},
{"type":"photo","id":"1762120856300310528","url":"https://pbs.twimg.com/media/GHRPlSsWUAA-35S.jpg?name=orig","width":816,"height":600},
{"type":"photo","id":"1762120856283578368","url":"https://pbs.twimg.com/media/GHRPlSoXAAAa6pn.jpg?name=orig","width":1066,"height":600}]}}}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a multi-photo tweet exposes every photo, its author and text',
      () async {
    final provider = TwitterProvider();
    final client =
        MockClient((_) async => http.Response(_censoredMenFixture, 200));

    final post = await provider.resolvePost(_censoredMenUri, client: client);

    expect(post, isNotNull);
    expect(post!.photos, hasLength(4));
    expect(post.title, 'Censored Men (@CensoredMen)');
    expect(post.text, 'Jacob Rothschild has died.');
    expect(post.photos.first.url.host, 'pbs.twimg.com');
    expect(post.photos.first.aspectRatio, closeTo(1290 / 720, 0.0001));
  });

  testWidgets('X photo post preview renders the photo at media-card scale',
      (tester) async {
    final photo = (await tester
        .runAsync(() => createTestImage(width: 1000, height: 1000)))!;

    final preview = UrlPreviewData(
      _republiqueUri,
      siteName: 'X (Twitter)',
      title: 'TRE-SP multa Samia Bomfim em R\$ 5 mil',
      type: UrlDestinationType.image,
      image: FixedImageProvider(photo),
    );

    await tester.pumpWidget(_testApp(UrlPreviewWidget(preview)));
    await tester.pump();

    final imageFinder = find.byType(Image);
    expect(imageFinder, findsOneWidget);

    final size = tester.getSize(imageFinder);
    expect(size.width, greaterThanOrEqualTo(360),
        reason: 'X photo previews render at media-card scale, not 300px');
    expect(size.height, greaterThanOrEqualTo(360),
        reason: 'X photo previews render at media-card scale, not 240px');
  });

  testWidgets('a page with an og:image renders a small side thumbnail',
      (tester) async {
    final image = (await tester
        .runAsync(() => createTestImage(width: 600, height: 315)))!;

    final preview = UrlPreviewData(
      Uri.parse('https://www.rfc-editor.org/info/rfc6716/'),
      siteName: 'RFC Editor',
      title: 'RFC 6716: Definition of the Opus Audio Codec | RFC Editor',
      description: 'This document defines the Opus interactive speech and '
          'audio codec.',
      type: UrlDestinationType.page,
      image: FixedImageProvider(image),
    );

    await tester.pumpWidget(_testApp(UrlPreviewWidget(preview)));
    await tester.pump();

    final imageFinder = find.byType(Image);
    expect(imageFinder, findsOneWidget);

    final size = tester.getSize(imageFinder);
    expect(size.width, lessThanOrEqualTo(120));
    expect(size.height, lessThanOrEqualTo(120));
  });

  testWidgets('a 4-photo tweet preview shows every photo in a grid',
      (tester) async {
    final images = <ui.Image>[
      for (var i = 0; i < 4; i++)
        (await tester
            .runAsync(() => createTestImage(width: 600, height: 600)))!,
    ];

    final preview = UrlPreviewData(
      _censoredMenUri,
      siteName: 'X (Twitter)',
      title: 'Jacob Rothschild has died.',
      type: UrlDestinationType.page,
      image: FixedImageProvider(images.first),
      images: [
        for (final image in images) UrlPreviewImage(FixedImageProvider(image)),
      ],
    );

    await tester.pumpWidget(_testApp(UrlPreviewWidget(preview)));
    await tester.pump();

    final imageFinders = find.byType(Image);
    expect(imageFinders, findsNWidgets(4));

    for (var i = 0; i < 4; i++) {
      final size = tester.getSize(imageFinders.at(i));
      expect(size.width, greaterThanOrEqualTo(190),
          reason: 'grid cells are cropped squares at media-card scale');
      expect(size.height, greaterThanOrEqualTo(190));
    }

    final cardWidth =
        tester.getSize(find.byKey(const ValueKey('url-preview-card'))).width;
    expect(cardWidth, greaterThanOrEqualTo(400));
  });
}
