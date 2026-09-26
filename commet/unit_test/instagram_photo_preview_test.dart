import 'dart:io';

import 'package:commet/client/components/url_preview/url_preview_component.dart';
import 'package:commet/client/components/video_embed/composite_video_provider.dart';
import 'package:commet/client/components/video_embed/providers/instagram_provider.dart';
import 'package:commet/client/matrix/components/url_preview/matrix_url_preview_component.dart';
import 'package:commet/client/matrix/matrix_client.dart';
import 'package:commet/client/room.dart';
import 'package:commet/client/timeline.dart';
import 'package:commet/client/timeline_events/timeline_event_message.dart';
import 'package:commet/ui/atoms/lightbox.dart';
import 'package:commet/ui/molecules/url_preview_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tiamat/config/style/theme_extensions.dart';

import 'test_image_provider.dart';

class _FakeMatrixClient implements MatrixClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRoom implements Room {
  @override
  bool get isE2EE => false;

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

Widget _testApp(Widget child) => MaterialApp(
      theme: ThemeData.light().copyWith(
        extensions: const [ThemeSettings()],
      ),
      home: Scaffold(body: Center(child: child)),
    );

final _eggUri = Uri.parse('https://www.instagram.com/p/BsOGulcndj-/');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('an Instagram photo post previews as its photo, not as a video',
      () async {
    final page = File('unit_test/fixtures/instagram_photo_embed.html')
        .readAsStringSync();
    CompositeVideoProvider.instance.registerProvider(InstagramProvider(
      canFetchEmbedData: true,
      httpClient: MockClient((_) async => http.Response(page, 200,
          headers: {'content-type': 'text/html; charset=utf-8'})),
    ));

    final component = MatrixUrlPreviewComponent(_FakeMatrixClient())
      ..serverSupportsUrlPreview = false;
    final data = await component.getPreview(
        _FakeTimeline(_FakeRoom()), _FakeMessage(_eggUri));

    expect(data, isNotNull);
    expect(data!.type, UrlDestinationType.image);
    expect(data.videoEmbedInfo, isNull);
    expect(data.siteName, 'Instagram');
    expect(data.title, '@world_record_egg');
    expect(data.description, startsWith('Let’s set a world record together'));
    expect(data.images, hasLength(1));
    expect((data.image! as NetworkImage).url,
        startsWith('https://scontent-gru1-1.cdninstagram.com/'));
  });

  testWidgets('a carousel preview opens every photo in the lightbox',
      (tester) async {
    final photos = [
      for (var i = 0; i < 6; i++)
        FixedImageProvider((await tester
            .runAsync(() => createTestImage(width: 600, height: 600)))!),
    ];

    await tester.pumpWidget(_testApp(UrlPreviewWidget(UrlPreviewData(
      Uri.parse('https://www.instagram.com/p/DW1xjVPCXJ0/'),
      siteName: 'Instagram',
      title: '@nasa',
      type: UrlDestinationType.image,
      image: photos.first,
      images: [for (final photo in photos) UrlPreviewImage(photo)],
    ))));
    await tester.pump();

    expect(find.byType(Image), findsNWidgets(4),
        reason: 'the grid shows the first four photos');

    await tester.tap(find.byType(Image).at(3));
    await tester.pumpAndSettle();

    final lightbox = tester.widget<Lightbox>(find.byType(Lightbox));
    expect(lightbox.gallery, photos,
        reason: 'the photos past the fourth are still one swipe away');
    expect(lightbox.initialIndex, 3);
  });
}
