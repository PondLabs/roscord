import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

/// A provider's embed page (YouTube, Instagram) in an iframe.
///
/// The page is the app's own origin, so unlike the native web views this
/// needs no loopback wrapper to give the provider a Referer. The iframe
/// attributes match `mediaEmbedWrapperHtml` so autoplay, fullscreen and
/// picture-in-picture behave the same as on the other platforms.
class OfficialEmbedFrame extends StatelessWidget {
  const OfficialEmbedFrame({required this.uri, super.key});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    return HtmlElementView.fromTagName(
      key: ValueKey(uri),
      tagName: 'iframe',
      onElementCreated: (element) {
        final frame = element as web.HTMLIFrameElement;
        frame
          ..src = uri.toString()
          ..allow = 'autoplay; encrypted-media; fullscreen; picture-in-picture'
          ..allowFullscreen = true
          ..referrerPolicy = 'strict-origin-when-cross-origin';
        frame.style
          ..border = '0'
          ..width = '100%'
          ..height = '100%'
          ..backgroundColor = '#000';
      },
    );
  }
}
