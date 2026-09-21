// Setting an mpv property on a media_kit player.
//
// media_kit's web player is an <audio> element: there is no mpv behind it,
// and its `NativePlayer` is a stub without `setProperty`, so a
// `player.platform is NativePlayer` check next to a `setProperty` call does
// not compile for the browser at all. This keeps that call in a file the web
// build never sees, and keeps every player importable on web.
import 'package:media_kit/media_kit.dart';

import 'mpv_property_native.dart'
    if (dart.library.js_interop) 'mpv_property_web.dart' as impl;

/// Sets mpv's [name] property for [player] on native; no-op on web.
Future<void> setMpvProperty(Player player, String name, String value) =>
    impl.setMpvProperty(player, name, value);
