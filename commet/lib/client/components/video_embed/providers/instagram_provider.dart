import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../photo_post.dart';
import '../video_capabilities.dart';
import '../video_embed_info.dart';
import '../video_playback_source.dart';
import '../video_provider.dart';

class InstagramPostInfo {
  final String shortcode;
  final bool isReel;

  const InstagramPostInfo({required this.shortcode, required this.isReel});
}

/// The post data an Instagram embed page carries (`gql_data.shortcode_media`).
class InstagramMedia {
  final bool isVideo;
  final Uri? videoUrl;
  final String? displayUrl;
  final int? width;
  final int? height;
  final Duration? duration;
  final String? caption;
  final String? username;
  final String? productType;

  /// Every photo of a photo post or carousel, in post order. Empty for a
  /// video post.
  final List<PostPhoto> photos;

  const InstagramMedia({
    required this.isVideo,
    this.videoUrl,
    this.displayUrl,
    this.width,
    this.height,
    this.duration,
    this.caption,
    this.username,
    this.productType,
    this.photos = const [],
  });

  double? get aspectRatio {
    final w = width;
    final h = height;
    if (w == null || h == null || h <= 0) return null;
    return w / h;
  }

  /// Reads the post out of an `/embed/captioned/` page. Null when the page
  /// holds no post: removed, private, or a layout Instagram has changed.
  static InstagramMedia? fromEmbedPage(String html) {
    final encoded = _contextJson.firstMatch(html)?.group(1);
    // A single photo's page has no post data (`"contextJSON":null`), only
    // the markup that draws it.
    if (encoded == null) return _fromEmbedMarkup(html);

    try {
      final context = jsonDecode(jsonDecode(encoded) as String);
      final media = (context as Map<String, dynamic>)['gql_data']
          ?['shortcode_media'] as Map<String, dynamic>?;
      if (media == null) return null;

      final dimensions = media['dimensions'] as Map<String, dynamic>?;
      final seconds = (media['video_duration'] as num?)?.toDouble();
      final captions =
          media['edge_media_to_caption']?['edges'] as List<dynamic>?;
      final caption = captions?.firstOrNull?['node']?['text'] as String?;
      final isVideo = media['is_video'] == true;
      final children =
          media['edge_sidecar_to_children']?['edges'] as List<dynamic>?;

      return InstagramMedia(
        isVideo: isVideo,
        videoUrl: Uri.tryParse(media['video_url'] as String? ?? ''),
        displayUrl: media['display_url'] as String?,
        width: (dimensions?['width'] as num?)?.toInt(),
        height: (dimensions?['height'] as num?)?.toInt(),
        duration: seconds == null
            ? null
            : Duration(milliseconds: (seconds * 1000).round()),
        caption: caption,
        username: media['owner']?['username'] as String?,
        productType: media['product_type'] as String?,
        photos: isVideo
            ? const []
            : [
                // A carousel's video slides show as their cover image.
                for (final node in children == null
                    ? [media]
                    : [for (final edge in children) edge['node']])
                  if (_photoOf(node) case final photo?) photo,
              ],
      );
    } catch (_) {
      return null;
    }
  }

  static PostPhoto? _photoOf(Object? node) {
    if (node is! Map<String, dynamic>) return null;
    final url = Uri.tryParse(node['display_url'] as String? ?? '');
    if (url == null || !url.hasAuthority) return null;
    final width = node['dimensions']?['width'] as num?;
    final height = node['dimensions']?['height'] as num?;
    return PostPhoto(
      url,
      aspectRatio: width == null || height == null || height <= 0
          ? null
          : width / height,
    );
  }

  /// The photo post the page draws without post data: the photo, whose
  /// frame's `padding-bottom` is its height over its width, then the author
  /// and caption. Only photo posts are read this way, as a video's URL is
  /// only in the post data.
  static InstagramMedia? _fromEmbedMarkup(String html) {
    // The page is mostly scripts. Parse just the embed, which runs up to
    // the next one: a tenth of the page.
    final attribute = html.indexOf('class="Embed"');
    if (attribute < 0) return null;
    final start = html.lastIndexOf('<', attribute);
    final end = html.indexOf('<script', attribute);
    final embed = html_parser
        .parseFragment(html.substring(start, end < 0 ? html.length : end))
        .querySelector('.Embed[data-media-type]');
    if (embed == null) return null;
    if (!const {'GraphImage', 'GraphSidecar'}
        .contains(embed.attributes['data-media-type'])) {
      return null;
    }

    final image = embed.querySelector('img.EmbeddedMediaImage');
    final src =
        _displayCopy(image?.attributes['srcset']) ?? image?.attributes['src'];
    final url = Uri.tryParse(src ?? '');
    if (url == null || !url.hasAuthority) return null;

    final frame = embed.querySelector('.EmbedFrame')?.attributes['style'];
    final padding =
        double.tryParse(_paddingBottom.firstMatch(frame ?? '')?.group(1) ?? '');

    return InstagramMedia(
      isVideo: false,
      displayUrl: url.toString(),
      caption: _captionOf(embed.querySelector('.Caption')),
      username: embed.querySelector('.UsernameText')?.text.trim(),
      photos: [
        PostPhoto(
          url,
          aspectRatio: padding == null || padding <= 0 ? null : 100 / padding,
        ),
      ],
    );
  }

  /// The widest copy in [srcset] at most 1080 wide, the size Instagram's
  /// own embed shows. `src` is the original, which can be 4000 wide. Square
  /// crops of the same widths come after the copies that keep the shape.
  static String? _displayCopy(String? srcset) {
    String? copy;
    var copyWidth = 0;
    for (final candidate in (srcset ?? '').split(',')) {
      if (candidate.trim().split(' ') case [final url, final size]
          when size.endsWith('w')) {
        final width = int.tryParse(size.substring(0, size.length - 1));
        if (width != null && width <= 1080 && width > copyWidth) {
          copy = url;
          copyWidth = width;
        }
      }
    }
    return copy;
  }

  /// The caption's text, which follows the author's name and ends where the
  /// comments link starts. Line breaks are `<br>`, hashtags are links.
  static String? _captionOf(dom.Element? caption) {
    if (caption == null) return null;
    final text = StringBuffer();
    for (final node in caption.nodes) {
      if (node is dom.Element) {
        if (node.classes.contains('CaptionUsername') ||
            node.classes.contains('CaptionComments')) {
          continue;
        }
        text.write(node.localName == 'br' ? '\n' : node.text);
      } else if (node is dom.Text) {
        text.write(node.data);
      }
    }
    final result = text.toString().trim();
    return result.isEmpty ? null : result;
  }

  /// The post data is a JSON string inside the page's `PolarisEmbedSimple`
  /// init arguments, so it is decoded twice.
  static final RegExp _contextJson =
      RegExp(r'"contextJSON":("(?:\\.|[^"\\])*")');

  static final RegExp _paddingBottom = RegExp(r'padding-bottom:\s*([\d.]+)%');
}

class InstagramProvider implements VideoProvider, PhotoPostProvider {
  InstagramProvider({http.Client? httpClient, bool? canFetchEmbedData})
      : _defaultHttpClient = httpClient,
        _canFetchEmbedData = canFetchEmbedData ?? !kIsWeb;

  final http.Client? _defaultHttpClient;

  /// Whether the embed page can be read here. A browser cannot: instagram.com
  /// sends no CORS headers, so the web build keeps the official embed.
  final bool _canFetchEmbedData;

  @override
  String get id => 'instagram';

  @override
  String get name => 'Instagram';

  @override
  VideoCapabilities get capabilities => VideoCapabilities.officialEmbed;

  /// instagram.com plus the "fixed embed" mirrors (ddinstagram, kkinstagram,
  /// instagramez) people paste to get working embeds elsewhere. They share
  /// instagram.com's paths, so every one resolves through instagram.com.
  static final RegExp _instagramDomainRegex = RegExp(
    r'^(?:(?:www|m)\.)?(?:instagram\.com|ddinstagram\.com|kkinstagram\.com|instagramez\.com)$',
    caseSensitive: false,
  );

  static const Set<String> _postTypes = {'reel', 'reels', 'p', 'tv'};

  @override
  bool canHandle(Uri uri) {
    final host = uri.host.toLowerCase();
    if (!_instagramDomainRegex.hasMatch(host)) return false;

    return extractPostInfo(uri) != null;
  }

  InstagramPostInfo? extractPostInfo(Uri uri) {
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    // /reel/<code>, or /<username>/reel/<code> as Instagram's own og:url has.
    for (final start in [0, 1]) {
      if (segments.length < start + 2) break;
      final type = segments[start].toLowerCase();
      if (_postTypes.contains(type)) {
        return InstagramPostInfo(
          shortcode: segments[start + 1],
          isReel: type == 'reel' || type == 'reels',
        );
      }
    }
    return null;
  }

  @override
  Future<VideoEmbedInfo?> resolve(
    Uri uri, {
    bool fetchPlayback = false,
    http.Client? client,
  }) async {
    final info = extractPostInfo(uri);
    if (info == null) return null;

    final media =
        _canFetchEmbedData ? await _fetchEmbedMedia(info, client) : null;
    if (media != null) {
      if (!media.isVideo || media.videoUrl == null) return null;
      return _nativeInfo(uri, info, media, fetchPlayback: fetchPlayback);
    }

    final isReel = info.isReel;
    final double defaultAspect = isReel ? (9.0 / 16.0) : 1.0;
    final platformName = isReel ? 'Instagram Reels' : 'Instagram';

    return VideoEmbedInfo(
      originalUrl: uri,
      // A /p/ link may hold photos as well as a video.
      title: isReel ? 'Instagram Reel' : 'Instagram Post',
      aspectRatio: defaultAspect,
      platformName: platformName,
      isShortForm: isReel,
      playbackSource: fetchPlayback
          ? OfficialVideoEmbedSource(
              Uri.https(
                'www.instagram.com',
                '/${isReel ? 'reel' : 'p'}/${info.shortcode}/embed/',
              ),
              provider: OfficialVideoProvider.instagram,
            )
          : null,
      capabilities: capabilities,
    );
  }

  /// A photo post or carousel, which [resolve] rejects. Null for a video
  /// post and wherever the embed page cannot be read.
  @override
  Future<PhotoPost?> resolvePost(Uri uri, {http.Client? client}) async {
    final info = extractPostInfo(uri);
    if (info == null || !_canFetchEmbedData) return null;

    final media = await _fetchEmbedMedia(info, client);
    if (media == null || media.photos.isEmpty) return null;

    final username = media.username;
    return PhotoPost(
      title: username != null ? '@$username' : null,
      text: media.caption?.trim() ?? '',
      photos: media.photos,
    );
  }

  /// A video Commet plays itself. The stream is only attached for playback:
  /// the video URL is signed and expires within days, so a preview that sits
  /// in the timeline fetches a fresh one when it is opened.
  VideoEmbedInfo _nativeInfo(
    Uri uri,
    InstagramPostInfo info,
    InstagramMedia media, {
    required bool fetchPlayback,
  }) {
    final isReel = info.isReel || media.productType == 'clips';
    final aspectRatio = media.aspectRatio ?? (isReel ? 9.0 / 16.0 : 1.0);
    final firstLine = media.caption
        ?.split('\n')
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    final author = media.username != null ? '@${media.username}' : null;
    final thumbnailUrl = media.displayUrl;
    final streamUrl = fetchPlayback ? media.videoUrl : null;

    return VideoEmbedInfo(
      originalUrl: uri,
      title: firstLine?.isNotEmpty == true
          ? firstLine!
          : (isReel ? 'Instagram Reel' : 'Instagram Video'),
      author: author,
      thumbnailUrl: thumbnailUrl,
      thumbnail: thumbnailUrl != null ? NetworkImage(thumbnailUrl) : null,
      streamUrl: streamUrl,
      playbackSource: streamUrl != null ? NativeVideoSource(streamUrl) : null,
      aspectRatio: aspectRatio,
      duration: media.duration,
      platformName: isReel ? 'Instagram Reels' : 'Instagram',
      isShortForm: isReel || aspectRatio < 0.85,
      capabilities: VideoCapabilities.native,
    );
  }

  Future<InstagramMedia?> _fetchEmbedMedia(
      InstagramPostInfo info, http.Client? client) async {
    final httpClient = client ?? _defaultHttpClient ?? http.Client();
    final shouldCloseClient = client == null && _defaultHttpClient == null;

    try {
      final embedUrl = Uri.https(
        'www.instagram.com',
        '/${info.isReel ? 'reel' : 'p'}/${info.shortcode}/embed/captioned/',
      );
      // Instagram only renders the embed for a page navigation (an iframe
      // loading it). Any other request gets the app shell, with no post in it.
      final res = await httpClient.get(embedUrl, headers: const {
        'Accept': 'text/html',
        'Sec-Fetch-Mode': 'navigate',
      }).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        return InstagramMedia.fromEmbedPage(
            utf8.decode(res.bodyBytes, allowMalformed: true));
      }
    } catch (_) {
      // Fallback
    } finally {
      if (shouldCloseClient) {
        httpClient.close();
      }
    }

    return null;
  }
}
