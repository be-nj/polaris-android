import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:polaris/core/client/api/api_client.dart';
import 'package:polaris/core/client/api/v8_dto.dart';
import 'package:polaris/core/client/guest_client.dart';
import 'package:polaris/core/connection.dart' as connection;
import 'package:polaris/core/sso.dart' as sso;
import 'package:shared_preferences/shared_preferences.dart';

const String authHostPreferenceKey = "polaris_auth_host";
const String tokenPreferenceKey = "polaris_auth_token";
const String usernamePreferenceKey = "polaris_auth_username";

enum Error {
  authenticationAlreadyInProgress,
  incorrectCredentials,
  ssoFailed,
  requestFailed,
  requestTimeout,
  unknownError,
}

extension _ToAuthenticationError on APIError {
  Error toAuthenticationError() {
    switch (this) {
      case APIError.unauthorized:
        return Error.incorrectCredentials;
      case APIError.requestFailed:
      case APIError.networkError:
      case APIError.unspecifiedHost:
      case APIError.responseParseError:
      case APIError.unexpectedCacheMiss:
      case APIError.notImplemented:
        return Error.requestFailed;
      case APIError.timeout:
        return Error.requestTimeout;
    }
  }
}

enum State {
  unauthenticated,
  reauthenticating,
  authenticating,
  authenticated,
}

class Manager extends ChangeNotifier {
  final http.Client httpClient;
  final connection.Manager connectionManager;
  final sso.Browser browser;

  State _state = State.unauthenticated;
  State get state => _state;
  String? _token;
  String? get token => _token;
  String? _username;
  String? get username => _username;

  Manager({
    required this.httpClient,
    required this.connectionManager,
    sso.Browser? browser,
  }) : browser = browser ?? sso.SystemBrowser() {
    connectionManager.addListener(() async => await _onConnectionStateChanged());
    _onConnectionStateChanged();
  }

  Future _onConnectionStateChanged() async {
    if (connectionManager.isConnected()) {
      _setState(State.unauthenticated);
      try {
        await _reauthenticate();
      } catch (e) {
        developer.log("Error during reauthentication", error: e);
      }
    }
  }

  Future _reauthenticate() async {
    assert(_state == State.unauthenticated);
    SharedPreferences preferences = await SharedPreferences.getInstance();
    final url = preferences.getString(authHostPreferenceKey);
    _token = preferences.getString(tokenPreferenceKey);
    _username = preferences.getString(usernamePreferenceKey);
    final isSameHost = url == connectionManager.url;
    final hasToken = _token?.isNotEmpty ?? false;
    final hasUsername = _username?.isNotEmpty ?? false;
    if (!hasToken || !hasUsername || !isSameHost) {
      return;
    }

    _setState(State.reauthenticating);
    try {
      final guestClient = GuestClient(connectionManager: connectionManager, httpClient: httpClient);
      await guestClient.testConnection(_token);
    } on APIError catch (e) {
      await _clear();
      _setState(State.unauthenticated);
      throw e.toAuthenticationError();
    } catch (e) {
      await _clear();
      _setState(State.unauthenticated);
      throw Error.unknownError;
    }

    _setState(State.authenticated);
  }

  Future authenticate(String newUsername, String password) async {
    if (_state != State.unauthenticated) {
      throw Error.authenticationAlreadyInProgress;
    }

    _setState(State.authenticating);
    Authorization authorization;
    try {
      final guestClient = GuestClient(connectionManager: connectionManager, httpClient: httpClient);
      authorization = await guestClient.login(newUsername, password);
    } on APIError catch (e) {
      _setState(State.unauthenticated);
      throw e.toAuthenticationError();
    } catch (e) {
      _setState(State.unauthenticated);
      throw Error.unknownError;
    }

    _setHost(connectionManager.url);
    _setUsername(newUsername);
    _setToken(authorization.token);
    _setState(State.authenticated);
  }

  /// Lists the single sign-on providers offered by the server, if any.
  Future<List<SSOProvider>> getSSOProviders() async {
    try {
      final guestClient = GuestClient(connectionManager: connectionManager, httpClient: httpClient);
      return await guestClient.getSSOProviders();
    } catch (e) {
      return [];
    }
  }

  /// Signs in through a single sign-on provider, using the web browser of the device.
  /// Returns false when the user left the browser without signing in.
  ///
  /// The browser cannot hand a session over to this app directly. Instead, the server ends the sign-in
  /// by opening a link to this app which contains a single-use code. This code can only be redeemed
  /// along with the code verifier, which never leaves this app.
  Future<bool> authenticateWithSSO(SSOProvider provider) async {
    if (_state != State.unauthenticated) {
      throw Error.authenticationAlreadyInProgress;
    }
    final host = connectionManager.url;
    if (host == null || !provider.loginURL.startsWith('/')) {
      throw Error.ssoFailed;
    }

    _setState(State.authenticating);
    Authorization authorization;
    try {
      final codeVerifier = sso.makeCodeVerifier();
      final codeChallenge = sso.makeCodeChallenge(codeVerifier);
      final loginURL = Uri.parse(host + provider.loginURL).replace(queryParameters: {'code_challenge': codeChallenge});

      final String callbackURL;
      try {
        callbackURL = await browser.authenticate(loginURL.toString());
      } on sso.CancelledException {
        _setState(State.unauthenticated);
        return false;
      }

      final code = sso.readCode(callbackURL);
      if (code == null || connectionManager.url != host) {
        _setState(State.unauthenticated);
        throw Error.ssoFailed;
      }

      final guestClient = GuestClient(connectionManager: connectionManager, httpClient: httpClient);
      authorization = await guestClient.redeemSSOCode(code, codeVerifier);
    } on Error {
      rethrow;
    } on APIError catch (e) {
      _setState(State.unauthenticated);
      throw e == APIError.requestFailed ? Error.ssoFailed : e.toAuthenticationError();
    } catch (e) {
      developer.log("Error during single sign-on", error: e);
      _setState(State.unauthenticated);
      throw Error.ssoFailed;
    }

    _setHost(host);
    _setUsername(authorization.username);
    _setToken(authorization.token);
    _setState(State.authenticated);
    return true;
  }

  bool isAuthenticated() {
    return state == State.authenticated;
  }

  void _setState(State newState) {
    if (_state == newState) {
      return;
    }
    _state = newState;
    notifyListeners();
  }

  Future _clear() async {
    await _setHost(null);
    await _setToken(null);
    await _setUsername(null);
  }

  Future _setHost(String? host) async {
    SharedPreferences preferences = await SharedPreferences.getInstance();
    if (host != null) {
      preferences.setString(authHostPreferenceKey, host);
    } else {
      preferences.remove(authHostPreferenceKey);
    }
  }

  Future _setToken(String? newToken) async {
    _token = newToken;
    SharedPreferences preferences = await SharedPreferences.getInstance();
    if (_token != null) {
      preferences.setString(tokenPreferenceKey, _token!);
    } else {
      preferences.remove(tokenPreferenceKey);
    }
  }

  Future _setUsername(String? newUsername) async {
    _username = newUsername;
    SharedPreferences preferences = await SharedPreferences.getInstance();
    if (_username != null) {
      preferences.setString(usernamePreferenceKey, _username!);
    } else {
      preferences.remove(usernamePreferenceKey);
    }
  }
}
