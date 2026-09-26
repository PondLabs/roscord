import 'package:http/http.dart' as http;

class PostPhoto {
  final Uri url;

  /// Width over height, when the post says.
  final double? aspectRatio;

  const PostPhoto(this.url, {this.aspectRatio});
}

/// A post as its own site shows it: author line, text and photos. Used to
/// build preview cards that don't fall back to the scraped og: card.
class PhotoPost {
  /// Who posted it, e.g. "Censored Men (@CensoredMen)" or "@nasa".
  final String? title;
  final String text;
  final List<PostPhoto> photos;

  const PhotoPost({this.title, this.text = '', this.photos = const []});
}

/// A provider whose links may hold photos instead of a video: an X status,
/// an Instagram post. When the provider's `resolve` finds no video, the
/// preview asks for the post instead.
abstract class PhotoPostProvider {
  /// The post as posted, or null when it cannot be read.
  Future<PhotoPost?> resolvePost(Uri uri, {http.Client? client});
}
