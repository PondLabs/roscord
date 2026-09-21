import 'package:media_kit/media_kit.dart';

Future<void> setMpvProperty(Player player, String name, String value) async {
  final native = player.platform;
  if (native is NativePlayer) {
    await native.setProperty(name, value);
  }
}
