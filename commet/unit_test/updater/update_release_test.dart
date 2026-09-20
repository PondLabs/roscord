// Reading a GitHub release the way the updater does. The payload below is
// the shape `ci.yml` produces: one archive per desktop platform, each with a
// sha256 digest.
import 'dart:convert';

import 'package:commet/utils/updater/update_release.dart';
import 'package:flutter_test/flutter_test.dart';

const _sha = '050a48713e7423467c39d1dcb688b4eff730665588db0b73872de2fd756aed50';

Map<String, Object?> _release({List<Map<String, Object?>>? assets}) => {
      'tag_name': 'v0.13.2',
      'draft': false,
      'prerelease': false,
      'assets': assets ??
          [
            {
              'name': 'roscord-v0.13.2-linux-x64-release.tar.gz',
              'browser_download_url': 'https://example.invalid/linux.tar.gz',
              'size': 60159051,
              'digest': 'sha256:$_sha',
            },
            {
              'name': 'roscord-v0.13.2-windows-x64-release.zip',
              'browser_download_url': 'https://example.invalid/windows.zip',
              'size': 66398720,
              'digest': 'sha256:${_sha.replaceFirst('0', '1')}',
            },
          ],
    };

UpdateRelease parse(Map<String, Object?> json) =>
    UpdateRelease.fromJson(jsonDecode(jsonEncode(json)))!;

void main() {
  test('a release yields its tag and both desktop archives', () {
    final release = parse(_release());
    expect(release.tag, 'v0.13.2');
    expect(release.assets.length, 2);

    final linux = release.assetFor('linux')!;
    expect(linux.name, 'roscord-v0.13.2-linux-x64-release.tar.gz');
    expect(linux.url, 'https://example.invalid/linux.tar.gz');
    expect(linux.size, 60159051);
    expect(linux.sha256, _sha);

    expect(release.assetFor('windows')!.name,
        endsWith('-windows-x64-release.zip'));
  });

  test('a platform with no archive in the release has none', () {
    final release = parse(_release(assets: [
      {
        'name': 'roscord-v0.13.2-linux-x64-release.tar.gz',
        'browser_download_url': 'https://example.invalid/linux.tar.gz',
        'size': 1,
        'digest': 'sha256:$_sha',
      }
    ]));
    expect(release.assetFor('linux'), isNotNull);
    expect(release.assetFor('windows'), isNull);
  });

  test('debug builds are never offered as an update', () {
    final release = parse(_release(assets: [
      {
        'name': 'roscord-v0.13.2-windows-x64-debug.zip',
        'browser_download_url': 'https://example.invalid/debug.zip',
        'size': 1,
        'digest': 'sha256:$_sha',
      }
    ]));
    expect(release.assetFor('windows'), isNull);
  });

  test('a digest that is not a sha256 is not taken for one', () {
    for (final digest in [
      'md5:$_sha',
      'sha256:not-hex',
      'sha256:${_sha.substring(0, 63)}',
      _sha,
    ]) {
      final release = parse(_release(assets: [
        {
          'name': 'roscord-v0.13.2-linux-x64-release.tar.gz',
          'browser_download_url': 'https://example.invalid/linux.tar.gz',
          'size': 1,
          'digest': digest,
        }
      ]));
      expect(release.assetFor('linux')!.sha256, isNull, reason: digest);
    }
  });

  test('a payload that is not a release at all is refused', () {
    expect(UpdateRelease.fromJson(null), isNull);
    expect(UpdateRelease.fromJson('nope'), isNull);
    expect(UpdateRelease.fromJson(<String, Object?>{}), isNull);
    // GitHub's rate limit reply: a message and no tag.
    expect(
        UpdateRelease.fromJson(
            <String, Object?>{'message': 'API rate limit exceeded'}),
        isNull);
  });

  test('an asset without a name or a url is dropped, the rest survive', () {
    final release = parse(_release(assets: [
      {'browser_download_url': 'https://example.invalid/x', 'size': 1},
      {'name': 'roscord-v0.13.2-linux-x64-release.tar.gz', 'size': 1},
      {
        'name': 'roscord-v0.13.2-windows-x64-release.zip',
        'browser_download_url': 'https://example.invalid/windows.zip',
        'size': 2,
        'digest': 'sha256:$_sha',
      },
    ]));
    expect(release.assets.length, 1);
    expect(release.assetFor('windows'), isNotNull);
  });
}
