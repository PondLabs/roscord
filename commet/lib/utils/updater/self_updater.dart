// Installing a new roscord over the running one, without a browser.
//
// Only the desktop builds can do this, and only the ones that were unpacked
// from the archive `ci.yml` publishes: an installed .deb or a flatpak belongs
// to its package manager, and Android and the web have their own ways. Where
// it cannot, [SelfUpdater.canInstall] is false and the button falls back to
// opening the release page, which is all the app ever did before.
//
// The shape of it: download the archive for this platform, check it against
// the sha256 GitHub reports, unpack it beside the install, then hand a small
// script the job of swapping the two directories once this process is gone
// and starting the new build. A running program cannot replace its own
// directory on Windows, so the last step has to outlive it.
import 'package:commet/utils/updater/update_release.dart';
import 'package:flutter/foundation.dart';

import 'self_updater_stub.dart' if (dart.library.io) 'self_updater_native.dart'
    as platform;

/// Where an update has got to. The button reads this to know what to show.
enum UpdateStage {
  /// Nothing has been asked for yet.
  idle,
  checking,
  upToDate,

  /// Newer, but this build installs updates by hand (see [SelfUpdater]).
  available,
  downloading,
  verifying,
  unpacking,

  /// Unpacked and waiting: the swap happens when the app next closes.
  ready,
  failed,
}

/// What the update button shows.
class UpdateProgress {
  const UpdateProgress(this.stage, {this.release, this.fraction, this.message});

  final UpdateStage stage;
  final UpdateRelease? release;

  /// 0..1 while downloading, null when there is nothing to show.
  final double? fraction;

  /// Why it failed, or what is up to date, in the user's words.
  final String? message;

  bool get busy => switch (stage) {
        UpdateStage.checking ||
        UpdateStage.downloading ||
        UpdateStage.verifying ||
        UpdateStage.unpacking =>
          true,
        _ => false,
      };
}

abstract class SelfUpdater {
  static SelfUpdater? _instance;
  static SelfUpdater get instance => _instance ??= platform.createSelfUpdater();

  /// Follows the update as it goes, for the settings page.
  ValueListenable<UpdateProgress> get progress;

  /// Whether this build can install an update over itself, as opposed to
  /// only pointing at the release page.
  bool get canInstall;

  /// Looks for a newer release and, when there is one and [canInstall],
  /// fetches and unpacks it. Safe to call again; does nothing while busy.
  Future<void> checkAndPrepare();

  /// Swaps in what [checkAndPrepare] unpacked and starts it. The caller
  /// closes the app straight after: the swap only happens once this process
  /// has gone. False when there is nothing staged or the handover failed,
  /// in which case nothing has been touched.
  Future<bool> installAndRestart();

  /// Drops anything staged, so a half-finished update is not left on disk.
  Future<void> discard();
}
