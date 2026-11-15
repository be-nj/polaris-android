import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

/// Scheme of the link the Polaris server opens at the end of a single sign-on (`polaris://sso?code=…`).
/// This must match the scheme declared in the Android manifest.
const callbackScheme = 'polaris';
const callbackHost = 'sso';

/// Thrown when the user leaves the browser without completing the sign-in.
class CancelledException implements Exception {}

/// Web browser the user signs in with. Single sign-on providers expect to be used from a real browser,
/// where the user may already be signed in and has access to their password manager or passkeys.
abstract class Browser {
  /// Opens `url` and returns the link the sign-in ended on, which uses [callbackScheme].
  Future<String> authenticate(String url);
}

class SystemBrowser implements Browser {
  @override
  Future<String> authenticate(String url) async {
    try {
      return await FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: callbackScheme);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') {
        throw CancelledException();
      }
      rethrow;
    }
  }
}

/// Secret which proves to the server that the app redeeming a sign-in is the one which started it.
String makeCodeVerifier() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

/// What the server is told about the code verifier before the user signs in.
String makeCodeChallenge(String codeVerifier) {
  final hash = sha256.convert(utf8.encode(codeVerifier));
  return base64UrlEncode(hash.bytes).replaceAll('=', '');
}

/// Reads the code handed over by the server from the link a sign-in ended on.
String? readCode(String callbackURL) {
  final uri = Uri.tryParse(callbackURL);
  if (uri == null || uri.scheme != callbackScheme || uri.host != callbackHost) {
    return null;
  }
  final code = uri.queryParameters['code'];
  return (code == null || code.isEmpty) ? null : code;
}
