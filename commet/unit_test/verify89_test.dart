import 'dart:io';
import 'package:commet/client/components/video_embed/composite_video_provider.dart';
import 'package:commet/client/components/video_embed/video_playability.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('walk the reported URL through the composite', () async {
    final bytes = File('unit_test/fixtures/fx_image_post.json').readAsBytesSync();
    final client = MockClient((_) async => http.Response.bytes(bytes, 200));
    final uri = Uri.parse('https://x.com/LifeNewsHQ/status/2100258667795001748');
    final composite = CompositeVideoProvider();

    print('canHandle: ${composite.canHandle(uri)}  <- always true for a tweet');
    final post = await composite.resolvePost(uri, client: client);
    print('images: ${post?.images.length}  video: ${post?.hasVideo}');
    print('photo: ${post?.images.first.url}');
    print('  ${post?.images.first.width}x${post?.images.first.height} ar=${post?.images.first.aspectRatio}');
    final video = await composite.resolve(uri, client: client);
    print('resolve() -> ${video == null ? "null (correct: no video)" : video}');
    print('playableEmbed -> ${playableEmbed(video) == null ? "null => NOT a video card" : "playable"}');
  });
}
