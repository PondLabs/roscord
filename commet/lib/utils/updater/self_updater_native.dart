// Desktop: download the release archive, check it, unpack it beside the
// install, and leave a script to put it in place once we are gone.
//
// The swap is a rename, not a copy over the top: a half-written install is
// the one outcome worth ruling out. The old directory is moved aside first
// and moved back if the new one will not go in, so a failure leaves the
// build that was already working.
import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:commet/config/build_config.dart';
import 'package:commet/debug/log.dart';
import 'package:commet/utils/updater/self_updater.dart';
import 'package:commet/utils/updater/update_release.dart';
import 'package:commet/utils/update_checker.dart';
import 'package:commet/utils/windows_hidden_process.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

SelfUpdater createSelfUpdater() => NativeSelfUpdater();

/// Directories an update must not touch, because something else owns what is
/// in them. A flatpak is read only at `/app`, and a .deb or a distro package
/// lives under `/usr`.
const _managedPrefixes = ['/usr/', '/app/', '/snap/', '/nix/store/'];

/// Whether a build living at [executable] is ours to replace.
///
/// Pulled out so it can be tested without an install to point at.
bool isSelfInstallable(String platform, String executable) {
  if (platform != 'windows' && platform != 'linux') return false;
  final path = executable.replaceAll('\\', '/');
  return !_managedPrefixes.any(path.startsWith);
}

/// Unpacks [archive] into [into].
///
/// The system's own tar first: `archive`'s pure Dart gzip and tar take about
/// three minutes over a release build, against a second or two for the tool
/// every desktop already has (Windows has shipped bsdtar, which reads zip
/// too, since Windows 10 1803). The Dart one is kept for whatever does not
/// have it, slow but working.
Future<void> unpack(File archive, Directory into) async {
  try {
    final tar =
        await _runQuietly('tar', ['-xf', archive.path, '-C', into.path]);
    if (tar == 0) return;
    Log.w('Update: tar exited $tar, unpacking in Dart instead');
  } catch (e, s) {
    Log.onError(e, s, content: 'Update: no system tar, unpacking in Dart');
  }
  // Leaves nothing half written for the Dart pass to trip over.
  for (final entry in into.listSync()) {
    entry.deleteSync(recursive: true);
  }
  await extractFileToDisk(archive.path, into.path);
}

Future<int> _runQuietly(String executable, List<String> arguments) async {
  if (!Platform.isWindows) {
    final result = await Process.run(executable, arguments);
    return result.exitCode;
  }
  // No console window for the user to watch flash past.
  final process = await startWindowsHidden(executable, arguments);
  return process.exitCode.timeout(const Duration(minutes: 5));
}

/// The one directory an archive holds, which is the new install.
///
/// `ci.yml` packs `roscord-<tag>-<platform>-x64-<mode>/` and nothing else.
/// Anything else is not an archive we made, and is refused rather than
/// guessed at.
Directory? singleRootOf(Directory unpacked) {
  final entries = unpacked.listSync();
  if (entries.length != 1) return null;
  final only = entries.first;
  return only is Directory ? only : null;
}

class NativeSelfUpdater implements SelfUpdater {
  @override
  final ValueNotifier<UpdateProgress> progress =
      ValueNotifier(const UpdateProgress(UpdateStage.idle));

  /// Unpacked and waiting for the app to close.
  Directory? _staged;
  bool _running = false;

  String get _platform => Platform.isWindows ? 'windows' : 'linux';

  Directory get _installDir =>
      File(Platform.resolvedExecutable).parent.absolute;

  @override
  bool get canInstall =>
      UpdateChecker.shouldCheckForUpdates &&
      isSelfInstallable(_platform, Platform.resolvedExecutable);

  void _set(UpdateStage stage,
          {UpdateRelease? release, double? fraction, String? message}) =>
      progress.value = UpdateProgress(stage,
          release: release ?? progress.value.release,
          fraction: fraction,
          message: message);

  @override
  Future<void> checkAndPrepare() async {
    if (_running) return;
    _running = true;
    try {
      _set(UpdateStage.checking);
      final release =
          await UpdateRelease.fetchLatest(UpdateChecker.releasesApiUrl);
      if (release == null) {
        _set(UpdateStage.failed,
            message: 'Could not reach GitHub to look for updates.');
        return;
      }
      if (!UpdateChecker.isNewer(release.tag, BuildConfig.VERSION_TAG)) {
        _set(UpdateStage.upToDate,
            release: release,
            message: 'roscord ${BuildConfig.VERSION_TAG} is the latest.');
        return;
      }
      if (!canInstall) {
        // Nothing to do but point at the download, as before.
        _set(UpdateStage.available, release: release);
        return;
      }
      await _prepare(release);
    } catch (e, s) {
      Log.onError(e, s, content: 'Update: could not prepare');
      _set(UpdateStage.failed, message: 'The update could not be prepared.');
    } finally {
      _running = false;
    }
  }

  Future<void> _prepare(UpdateRelease release) async {
    final asset = release.assetFor(_platform);
    if (asset == null) {
      _set(UpdateStage.available,
          release: release,
          message: 'That release has no build for this platform.');
      return;
    }
    if (asset.sha256 == null) {
      // Without a checksum there is no way to know what arrived, and this
      // unpacks over the app: the browser can have this one.
      _set(UpdateStage.available,
          release: release,
          message: 'That release is not checksummed, so it has to be '
              'installed by hand.');
      return;
    }

    await discard();
    // Beside the install, so putting it in place is a rename and not a copy
    // across filesystems. Falls back to the temp directory when the parent
    // is not ours to write in.
    final work = await _workDirectory(release.tag);
    try {
      final archive = File(p.join(work.path, asset.name));
      _set(UpdateStage.downloading, release: release, fraction: 0);
      await _download(asset, archive);

      _set(UpdateStage.verifying, release: release);
      final digest = await sha256.bind(archive.openRead()).first;
      final got = digest.toString();
      if (got != asset.sha256) {
        throw StateError('checksum is $got, expected ${asset.sha256}');
      }

      _set(UpdateStage.unpacking, release: release);
      final unpacked = Directory(p.join(work.path, 'unpacked'));
      await unpacked.create(recursive: true);
      await unpack(archive, unpacked);
      await archive.delete();

      final root = singleRootOf(unpacked);
      if (root == null) {
        throw StateError('the archive does not hold one directory');
      }
      if (!await File(p.join(root.path, _executableName)).exists()) {
        throw StateError('no $_executableName in the archive');
      }
      _staged = root;
      _set(UpdateStage.ready, release: release);
      Log.i('Update: ${release.tag} is unpacked at ${root.path}');
    } catch (e, s) {
      Log.onError(e, s, content: 'Update: could not stage ${release.tag}');
      await _delete(work);
      _set(UpdateStage.failed,
          release: release,
          message: 'The update could not be downloaded. '
              'You can still install it from the release page.');
    }
  }

  String get _executableName => p.basename(Platform.resolvedExecutable);

  Future<Directory> _workDirectory(String tag) async {
    final beside =
        Directory(p.join(_installDir.parent.path, '.roscord-update'));
    try {
      await beside.create(recursive: true);
      // Writable in practice, not only on paper.
      final probe = File(p.join(beside.path, '.probe'));
      await probe.writeAsString('');
      await probe.delete();
      return beside;
    } catch (_) {
      final temp =
          Directory(p.join(Directory.systemTemp.path, 'roscord-update-$tag'));
      await temp.create(recursive: true);
      return temp;
    }
  }

  Future<void> _download(UpdateAsset asset, File target) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(asset.url));
      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: request.uri);
      }
      final total = response.contentLength > 0
          ? response.contentLength
          : (asset.size > 0 ? asset.size : 0);
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk
            in response.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) {
            _set(UpdateStage.downloading, fraction: received / total);
          }
        }
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<bool> installAndRestart() async {
    final staged = _staged;
    if (staged == null || !await staged.exists()) return false;
    try {
      final script = await _writeSwapScript(staged);
      await _spawnDetached(script);
      Log.i('Update: handed the swap to ${script.path}');
      return true;
    } catch (e, s) {
      Log.onError(e, s, content: 'Update: could not start the installer');
      _set(UpdateStage.failed,
          message: 'The update could not be started. Nothing was changed.');
      return false;
    }
  }

  @override
  Future<void> discard() async {
    final staged = _staged;
    _staged = null;
    if (staged == null) return;
    // The whole working directory, not only what was unpacked.
    await _delete(staged.parent.parent);
  }

  Future<void> _delete(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e, s) {
      Log.onError(e, s, content: 'Update: could not clean up ${dir.path}');
    }
  }

  Future<File> _writeSwapScript(Directory staged) async {
    final install = _installDir.path;
    final exe = p.join(install, _executableName);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final script = File(p.join(
        staged.parent.path, Platform.isWindows ? 'install.ps1' : 'install.sh'));
    await script.writeAsString(Platform.isWindows
        ? windowsSwapScript(
            waitFor: pid,
            staged: staged.path,
            install: install,
            exe: exe,
            work: staged.parent.parent.path,
            stamp: stamp)
        : linuxSwapScript(
            waitFor: pid,
            staged: staged.path,
            install: install,
            exe: exe,
            work: staged.parent.parent.path,
            stamp: stamp));
    if (!Platform.isWindows) {
      await Process.run('chmod', ['+x', script.path]);
    }
    return script;
  }

  Future<void> _spawnDetached(File script) async {
    if (Platform.isWindows) {
      // No console window: this outlives the app and the user should not
      // see a terminal flash up as it closes.
      await startWindowsHidden('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script.path,
      ]);
    } else {
      await Process.start('/bin/sh', [script.path],
          mode: ProcessStartMode.detached);
    }
  }
}

/// Single-quoted for PowerShell, where a quote is doubled to escape it.
String _ps(String value) => "'${value.replaceAll("'", "''")}'";

/// Single-quoted for the shell, where a quote ends the string, is escaped,
/// and the string starts again.
String _sh(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Swaps [install] for [staged] once the process [waitFor] is gone, starts
/// [exe] and clears up. The old install is moved aside first and moved back
/// if the new one will not go in, so a failure leaves what was working.
///
/// Pulled out of the updater so the scripts can be read, and run against a
/// directory that is not an install, in tests.
String windowsSwapScript({
  required int waitFor,
  required String staged,
  required String install,
  required String exe,
  required String work,
  required int stamp,
}) =>
    '''
\$ErrorActionPreference = 'Stop'
# Wait for roscord to go: its directory cannot be renamed while it runs.
\$deadline = (Get-Date).AddSeconds(60)
while ((Get-Process -Id $waitFor -ErrorAction SilentlyContinue) -and
       ((Get-Date) -lt \$deadline)) {
  Start-Sleep -Milliseconds 200
}
\$install = ${_ps(install)}
\$staged  = ${_ps(staged)}
\$old     = ${_ps('$install.old-$stamp')}
Move-Item -LiteralPath \$install -Destination \$old
try {
  Move-Item -LiteralPath \$staged -Destination \$install
} catch {
  # Put back what was working and leave the update where it is.
  Move-Item -LiteralPath \$old -Destination \$install
  throw
}
Start-Process -FilePath ${_ps(exe)} -WorkingDirectory \$install
Remove-Item -LiteralPath \$old -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath ${_ps(work)} -Recurse -Force -ErrorAction SilentlyContinue
''';

String linuxSwapScript({
  required int waitFor,
  required String staged,
  required String install,
  required String exe,
  required String work,
  required int stamp,
}) =>
    '''
#!/bin/sh
# Wait for roscord to go, so the new build does not start beside the old one.
i=0
while [ \$i -lt 300 ] && kill -0 $waitFor 2>/dev/null; do
  sleep 0.2
  i=\$((i + 1))
done
# Unlike Windows, a directory here can be moved out from under a running
# program. Waiting out rather than swapping under it: two roscords sharing
# one account is worse than an update that did not happen.
if kill -0 $waitFor 2>/dev/null; then
  exit 1
fi
install=${_sh(install)}
staged=${_sh(staged)}
old=${_sh('$install.old-$stamp')}
mv "\$install" "\$old" || exit 1
if ! mv "\$staged" "\$install"; then
  mv "\$old" "\$install"
  exit 1
fi
(cd "\$install" && exec ${_sh(exe)}) &
# Last, and from outside it: this script lives in there.
cd /
rm -rf "\$old" ${_sh(work)}
''';
