import 'package:flutter/widgets.dart';

/// A provider's embed page in an iframe, which only the web build has.
/// Native platforms play official embeds through CEF or a web view instead,
/// so this is never built there.
class OfficialEmbedFrame extends StatelessWidget {
  const OfficialEmbedFrame({required this.uri, super.key});

  final Uri uri;

  @override
  Widget build(BuildContext context) =>
      throw UnsupportedError('OfficialEmbedFrame only exists on web');
}
