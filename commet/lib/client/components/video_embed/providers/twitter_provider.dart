import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../photo_post.dart';
import '../video_capabilities.dart';
import '../video_embed_info.dart';
import '../video_playback_source.dart';
import '../video_provider.dart';

class TwitterStatusInfo {
  final String username;
  final String statusId;

  const TwitterStatusInfo({required this.username, required this.statusId});
}

class TwitterProvider implements VideoProvider, PhotoPostProvider {
  TwitterProvider({http.Client? httpClient}) : _defaultHttpClient = httpClient;

  final http.Client? _defaultHttpClient;

  @override
  String get id => 'twitter';

  @override
  String get name => 'X (Twitter)';

  @override
  VideoCapabilities get capabilities => VideoCapabilities.native;

  /// Matches twitter.com / x.com plus the common "fixup" mirrors
  /// (fxtwitter, fixupx, vxtwitter, fixvx, twittpr) that people paste to get
  /// working embeds elsewhere. They all share the /<user>/status/<id> layout
  /// and resolve through the same fxtwitter API.
  static final RegExp _twitterDomainRegex = RegExp(
    r'^(?:(?:www|mobile)\.)?(?:twitter\.com|x\.com|fxtwitter\.com|fixupx\.com|vxtwitter\.com|fixvx\.com|twittpr\.com)$',
    caseSensitive: false,
  );

  @override
  bool canHandle(Uri uri) {
    final host = uri.host.toLowerCase();
    if (!_twitterDomainRegex.hasMatch(host)) return false;

    return extractStatusInfo(uri) != null;
  }

  TwitterStatusInfo? extractStatusInfo(Uri uri) {
    final segments = uri.pathSegments;
    final statusIdx = segments.indexOf('status');
    if (statusIdx > 0 && statusIdx + 1 < segments.length) {
      final username = segments[statusIdx - 1];
      final statusId = segments[statusIdx + 1];
      if (RegExp(r'^\d+$').hasMatch(statusId)) {
        return TwitterStatusInfo(username: username, statusId: statusId);
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
    final info = extractStatusInfo(uri);
    if (info == null) return null;

    final tweet = await _fetchTweet(info, client);
    if (tweet == null) return null;

    final author = tweet['author'] as Map<String, dynamic>?;
    final authorName = author != null
        ? '${author['name']} (@${author['screen_name']})'
        : info.username;

    final text = tweet['text'] as String? ?? '';
    final media = tweet['media'] as Map<String, dynamic>?;
    final videos = media?['videos'] as List<dynamic>?;

    // Invariant: strictly differentiate tweets with video vs text/image only.
    // Image posts go through [resolvePhoto] instead.
    if (videos == null || videos.isEmpty) {
      return null;
    }

    final video = videos.first as Map<String, dynamic>;
    final vUrl = video['url'] as String?;
    final streamUrl = vUrl != null ? Uri.tryParse(vUrl) : null;
    final thumbUrl = video['thumbnail_url'] as String?;

    double? aspectRatio;
    final width = (video['width'] as num?)?.toDouble();
    final height = (video['height'] as num?)?.toDouble();
    if (width != null && height != null && height > 0) {
      aspectRatio = width / height;
    }

    Duration? duration;
    final durSeconds = (video['duration'] as num?)?.toDouble();
    if (durSeconds != null) {
      duration = Duration(milliseconds: (durSeconds * 1000).round());
    }

    final isVertical = aspectRatio != null && aspectRatio < 0.85;

    return VideoEmbedInfo(
      originalUrl: uri,
      title: text.isNotEmpty ? text : 'Post from $authorName',
      author: authorName,
      thumbnailUrl: thumbUrl,
      thumbnail: thumbUrl != null ? NetworkImage(thumbUrl) : null,
      streamUrl: streamUrl,
      playbackSource: streamUrl != null ? NativeVideoSource(streamUrl) : null,
      aspectRatio: aspectRatio ?? 16.0 / 9.0,
      duration: duration,
      platformName: 'X (Twitter)',
      isShortForm: isVertical,
      capabilities: capabilities,
    );
  }

  /// The status as posted (author, text, every photo), for previewing image
  /// posts, which [resolve] rejects. Null when the status cannot be fetched.
  @override
  Future<PhotoPost?> resolvePost(Uri uri, {http.Client? client}) async {
    final info = extractStatusInfo(uri);
    if (info == null) return null;

    final tweet = await _fetchTweet(info, client);
    if (tweet == null) return null;

    final author = tweet['author'] as Map<String, dynamic>?;
    final media = tweet['media'] as Map<String, dynamic>?;
    final photos = media?['photos'] as List<dynamic>? ?? const [];

    return PhotoPost(
      title: _authorLine(
          author?['name'] as String?, author?['screen_name'] as String?),
      text: tweet['text'] as String? ?? '',
      photos: [
        for (final photo in photos)
          if (photo is Map<String, dynamic>)
            if (Uri.tryParse(photo['url'] as String? ?? '') case final url?)
              PostPhoto(
                url,
                aspectRatio: _aspectRatio(photo['width'], photo['height']),
              ),
      ],
    );
  }

  /// "Censored Men (@CensoredMen)", or whichever half the status carried.
  static String? _authorLine(String? name, String? handle) {
    if (name == null) return handle != null ? '@$handle' : null;
    return handle != null ? '$name (@$handle)' : name;
  }

  static double? _aspectRatio(Object? width, Object? height) {
    if (width is! num || height is! num || height <= 0) return null;
    return width / height;
  }

  Future<Map<String, dynamic>?> _fetchTweet(
      TwitterStatusInfo info, http.Client? client) async {
    final httpClient = client ?? _defaultHttpClient ?? http.Client();
    final shouldCloseClient = client == null && _defaultHttpClient == null;

    try {
      final apiUrl = Uri.parse(
          'https://api.fxtwitter.com/${info.username}/status/${info.statusId}');
      final res =
          await httpClient.get(apiUrl).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['tweet'] as Map<String, dynamic>?;
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
