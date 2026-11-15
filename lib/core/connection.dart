import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:polaris/core/client/api/api_client.dart';
import 'package:polaris/core/client/api/v8_dto.dart' as dto;
import 'package:polaris/core/client/guest_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String hostPreferenceKey = "polaris_server_url";

abstract class ManagerInterface {
  String? get url;
  int? get apiVersion;
  bool isConnected();
}

enum Error {
  connectionAlreadyInProgress,
  unsupportedAPIVersion,
  networkError,
  requestFailed,
  requestTimeout,
  unknownError,
}

extension _ToConnectionError on APIError {
  Error toConnectionError() {
    switch (this) {
      case APIError.unauthorized:
      case APIError.requestFailed:
      case APIError.responseParseError:
      case APIError.unexpectedCacheMiss:
        return Error.requestFailed;
      case APIError.networkError:
      case APIError.unspecifiedHost:
        return Error.networkError;
      case APIError.timeout:
        return Error.requestTimeout;
      case APIError.notImplemented:
        return Error.unsupportedAPIVersion;
    }
  }
}

enum State {
  disconnected,
  connecting,
  reconnecting,
  connected,
  offlineMode,
}

class Manager extends ChangeNotifier implements ManagerInterface {
  http.Client httpClient;

  State _state = State.disconnected;
  State get state => _state;

  String? _url;
  @override
  String? get url => _url;

  int? _apiVersion;
  @override
  int? get apiVersion => _apiVersion;

  int? _apiMinorVersion;
  int? get apiMinorVersion => _apiMinorVersion;

  State? _previousState;
  State? get previousState => _previousState;

  Manager({required this.httpClient}) {
    reconnect();
  }

  Future reconnect() async {
    assert(_state == State.disconnected);
    SharedPreferences prefs = await SharedPreferences.getInstance();
    _url = prefs.getString(hostPreferenceKey);
    if (_url?.isEmpty ?? true) {
      return;
    }

    _setState(State.reconnecting);
    try {
      await _tryConnect();
    } catch (e) {
      developer.log("Error during reconnect", error: e);
    }
  }

  Future connect(String newURL) async {
    if (_state != State.disconnected) {
      throw Error.connectionAlreadyInProgress;
    }

    _setURL(newURL);
    _setState(State.connecting);

    // Addresses typed without a scheme are tried over HTTPS first, which is how servers exposed
    // to the internet are reached. Servers on a home network commonly only speak HTTP.
    final insecureURL = url;
    if (insecureURL != null && !_hasScheme(newURL)) {
      final secureURL = insecureURL.replaceFirst('http://', 'https://');
      final isSecureServer = await _isPolarisServer(secureURL);
      if (isSecureServer && url == insecureURL && state == State.connecting) {
        _url = secureURL;
      }
    }

    return await _tryConnect();
  }

  Future<bool> _isPolarisServer(String serverURL) async {
    try {
      final request = http.Request('GET', Uri.parse(serverURL + apiVersionEndpoint));
      final response = await httpClient.send(request).timeout(const Duration(seconds: 4));
      final body = await response.stream.bytesToString().timeout(const Duration(seconds: 4));
      if (response.statusCode != 200) {
        return false;
      }
      dto.APIVersion.fromJson(jsonDecode(body));
      return true;
    } catch (e) {
      return false;
    }
  }

  void disconnect() {
    _setState(State.disconnected);
  }

  @override
  bool isConnected() {
    return state == State.connected;
  }

  void startOffline() {
    if (state == State.disconnected) {
      _setState(State.offlineMode);
    }
  }

  bool canToggleOfflineMode() {
    return state == State.connected || (state == State.offlineMode && _previousState == State.connected);
  }

  void toggleOfflineMode() {
    if (!canToggleOfflineMode()) {
      return;
    }
    if (state == State.connected) {
      _setState(State.offlineMode);
    } else if (state == State.offlineMode) {
      _setState(State.connected);
    }
  }

  /// Servers reached through a reverse proxy commonly redirect plain HTTP requests to HTTPS.
  /// The HTTP client only follows such redirections for GET requests, so that connecting would
  /// work while signing in (a POST request) would not. This looks for such a redirection, in
  /// order to use the HTTPS address from then on. It also avoids sending credentials unencrypted.
  Future<String?> _findSecureURL(String insecureURL) async {
    if (!insecureURL.startsWith('http://')) {
      return null;
    }
    try {
      final request = http.Request('GET', Uri.parse(insecureURL + apiVersionEndpoint));
      request.followRedirects = false;
      final response = await httpClient.send(request).timeout(const Duration(seconds: 5));
      unawaited(response.stream.drain<void>().catchError((_) {}));
      if (!const [301, 302, 307, 308].contains(response.statusCode)) {
        return null;
      }
      final location = Uri.tryParse(response.headers['location'] ?? '');
      final isSameServer = location != null && location.scheme == 'https' && location.host == request.url.host;
      if (!isSameServer) {
        return null;
      }
      // Only trust redirections which keep the path as is, others may lead somewhere unrelated
      var secureURL = location.replace(query: null, fragment: null).toString();
      for (final suffix in [apiVersionEndpoint, apiVersionEndpoint.substring(0, apiVersionEndpoint.length - 1)]) {
        if (secureURL.endsWith(suffix)) {
          secureURL = secureURL.substring(0, secureURL.length - suffix.length);
          return secureURL == insecureURL.replaceFirst('http://', 'https://') ? secureURL : null;
        }
      }
    } catch (e) {
      developer.log("Could not determine whether the server redirects to HTTPS", error: e);
    }
    return null;
  }

  Future _tryConnect() async {
    assert(state == State.connecting || state == State.reconnecting);

    final initialURL = url;
    if (initialURL != null) {
      final secureURL = await _findSecureURL(initialURL);
      // The user may have disconnected or connected elsewhere in the meantime
      if (secureURL != null && url == initialURL && (state == State.connecting || state == State.reconnecting)) {
        _url = secureURL;
      }
    }

    dto.APIVersion serverAPIVersion;
    try {
      GuestClient guestClient = GuestClient(httpClient: httpClient, connectionManager: this);
      serverAPIVersion = await guestClient.getAPIVersion();
    } on APIError catch (e) {
      _setState(State.disconnected);
      throw e.toConnectionError();
    } catch (e) {
      _setState(State.disconnected);
      throw Error.unknownError;
    }

    if (serverAPIVersion.major < 6 || serverAPIVersion.major > 8) {
      _setState(State.disconnected);
      throw Error.unsupportedAPIVersion;
    }
    _apiVersion = serverAPIVersion.major;
    _apiMinorVersion = serverAPIVersion.minor;

    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? currentURL = url;
    if (currentURL != null) {
      prefs.setString(hostPreferenceKey, currentURL);
    }

    _setState(State.connected);
  }

  void _setState(State newState) {
    if (_state == newState) {
      return;
    }
    _previousState = state;
    _state = newState;
    notifyListeners();
  }

  void _setURL(String? newURL) {
    if (newURL != null) {
      newURL = _cleanURL(newURL);
    }
    _url = newURL;
  }

  bool _hasScheme(String url) {
    return RegExp(r'^https?://', caseSensitive: false).hasMatch(url.trim());
  }

  String _cleanURL(String url) {
    url = url.trim();
    if (!_hasScheme(url)) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }
}
