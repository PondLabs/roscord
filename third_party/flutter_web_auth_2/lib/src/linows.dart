import 'dart:async';

import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_web_auth_2/src/server.dart';
import 'package:flutter_web_auth_2_platform_interface/flutter_web_auth_2_platform_interface.dart';

/// Implements the plugin interface for Linux and Windows (Linows).
class FlutterWebAuth2LinowsPlugin extends FlutterWebAuth2Platform {
  final FlutterWebAuth2Platform _serverImpl = FlutterWebAuth2ServerPlugin();

  /// Registers the Linows super-implementation.
  static void registerWith() {
    FlutterWebAuth2Platform.instance = FlutterWebAuth2LinowsPlugin();
  }

  @override
  Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    required Map<String, dynamic> options,
  }) async {
    // COMMET: the CEF cutover (#132) deleted the in-app webview module and
    // its desktop webview dependency. Desktop SSO always authenticates
    // through the external system browser plus the loopback server, which is
    // also what roscord requests with useWebview: false.
    return _serverImpl.authenticate(
      url: url,
      callbackUrlScheme: callbackUrlScheme,
      options: options,
    );
  }

  @override
  Future clearAllDanglingCalls() async {
    await _serverImpl.clearAllDanglingCalls();
  }
}
