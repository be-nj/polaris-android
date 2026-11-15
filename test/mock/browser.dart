import 'dart:async';
import 'package:polaris/core/sso.dart' as sso;

/// Stands in for the web browser users sign in with.
class Browser implements sso.Browser {
  final List<String> visitedURLs = [];
  Completer<String>? _pendingSignIn;

  @override
  Future<String> authenticate(String url) {
    visitedURLs.add(url);
    _pendingSignIn = Completer<String>();
    return _pendingSignIn!.future;
  }

  /// The code challenge the app sent along when opening the browser.
  String? get codeChallenge => Uri.parse(visitedURLs.last).queryParameters['code_challenge'];

  /// The sign-in ends with the server opening this link, which leads back to the app.
  void completeSignIn(String callbackURL) {
    _pendingSignIn!.complete(callbackURL);
  }

  /// The user closes the browser without signing in.
  void cancelSignIn() {
    _pendingSignIn!.completeError(sso.CancelledException());
  }
}
