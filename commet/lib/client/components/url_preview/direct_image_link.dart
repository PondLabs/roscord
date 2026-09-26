import 'package:commet/client/components/url_preview/url_preview_component.dart';
import 'package:commet/utils/mime.dart';
import 'package:flutter/painting.dart';

/// A link straight to an image file, like `https://example.com/photo.png`.
///
/// The client loads these itself instead of asking the homeserver for a
/// preview. Image hosts often turn the homeserver's fetcher away (Akamai
/// answers Synapse with a 403), and there is nothing but the image to show
/// anyway. It also means an encrypted room's links never reach the
/// homeserver.
class DirectImageLink {
  static bool matches(Uri uri) {
    if (uri.scheme != "https") return false;

    final segments = uri.pathSegments;
    if (segments.isEmpty) return false;

    final name = segments.last;
    final dot = name.lastIndexOf(".");
    if (dot == -1) return false;

    return Mime.fromExtenstion(name.substring(dot + 1).toLowerCase()) != null;
  }

  static UrlPreviewData preview(Uri uri) {
    return UrlPreviewData(
      uri,
      type: UrlDestinationType.image,
      // Most image hosts send no CORS headers, so on web the bytes can't be
      // fetched and the image is shown as an <img> element instead.
      image: NetworkImage(uri.toString(),
          webHtmlElementStrategy: WebHtmlElementStrategy.fallback),
    );
  }
}
