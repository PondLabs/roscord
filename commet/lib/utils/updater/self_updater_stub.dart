// Web: there is nothing to install over. Reloading the page is the update.
import 'package:commet/utils/updater/self_updater.dart';
import 'package:flutter/foundation.dart';

SelfUpdater createSelfUpdater() => _NoSelfUpdater();

class _NoSelfUpdater implements SelfUpdater {
  @override
  final ValueNotifier<UpdateProgress> progress =
      ValueNotifier(const UpdateProgress(UpdateStage.idle));

  @override
  bool get canInstall => false;

  @override
  Future<void> checkAndPrepare() async {}

  @override
  Future<bool> installAndRestart() async => false;

  @override
  Future<void> discard() async {}
}
