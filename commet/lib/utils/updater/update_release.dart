// A release on GitHub, and the file of it this build would install.
//
// `ci.yml` cuts a release for every push to main and attaches one archive per
// desktop platform, named `roscord-<tag>-<platform>-x64-<mode>`, each holding
// a single top level directory of the same name. GitHub reports a sha256 for
// every asset, which is what makes installing one without a browser
// defensible: the download is checked against it before anything is unpacked.
import 'dart:convert';

import 'package:commet/debug/log.dart';
import 'package:http/http.dart' as http;

/// One file attached to a release.
class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.url,
    required this.size,
    required this.sha256,
  });

  final String name;
  final String url;
  final int size;

  /// Lower case hex, or null when GitHub did not report one: without it the
  /// download cannot be checked and is not installed.
  final String? sha256;

  static UpdateAsset? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final name = json['name'];
    final url = json['browser_download_url'];
    if (name is! String || url is! String) return null;
    final size = json['size'];
    // "sha256:<hex>", the only algorithm GitHub uses here today.
    final digest = json['digest'];
    final sha = digest is String && digest.startsWith('sha256:')
        ? digest.substring(7).toLowerCase()
        : null;
    return UpdateAsset(
      name: name,
      url: url,
      size: size is int ? size : 0,
      sha256:
          sha != null && RegExp(r'^[0-9a-f]{64}$').hasMatch(sha) ? sha : null,
    );
  }
}

class UpdateRelease {
  const UpdateRelease({required this.tag, required this.assets});

  final String tag;
  final List<UpdateAsset> assets;

  /// The archive built for [platform] (`windows` or `linux`), if this release
  /// has one. Release builds only: a debug bundle is not something to hand
  /// somebody as an update.
  UpdateAsset? assetFor(String platform) {
    final suffix = platform == 'windows' ? '.zip' : '.tar.gz';
    final wanted = '-$platform-x64-release$suffix';
    for (final asset in assets) {
      if (asset.name.endsWith(wanted)) return asset;
    }
    return null;
  }

  static UpdateRelease? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final tag = json['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final assets = json['assets'];
    return UpdateRelease(
      tag: tag,
      assets: assets is List
          ? assets.map(UpdateAsset.fromJson).whereType<UpdateAsset>().toList()
          : const [],
    );
  }

  /// The newest release, or null when the request failed or said something
  /// unexpected. Never throws: no part of this is worth breaking over.
  static Future<UpdateRelease?> fetchLatest(String apiUrl) async {
    try {
      final response = await http.get(Uri.parse(apiUrl), headers: {
        // GitHub's stable JSON media type. Dart supplies its own User-Agent.
        'Accept': 'application/vnd.github+json',
      }).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        Log.i('Update check failed: HTTP ${response.statusCode}');
        return null;
      }
      return fromJson(jsonDecode(response.body));
    } catch (e, s) {
      Log.onError(e, s, content: 'Update check failed');
      return null;
    }
  }
}
