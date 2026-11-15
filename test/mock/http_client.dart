import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/http.dart';
import 'package:mocktail/mocktail.dart' as mocktail;
import 'package:polaris/core/client/api/v8_dto.dart';
import 'package:polaris/core/client/api/v8_client.dart';
import 'package:polaris/core/client/guest_client.dart' show ssoProvidersEndpoint, ssoTokenEndpoint;
import 'package:polaris/core/sso.dart';

const goodHost = 'my-polaris-server';
const badHost = 'not-a-polaris-server';
const incompatibleHost = 'incompatible-polaris-server';
const goodHostURI = 'http://$goodHost';
const badHostURI = 'http://$badHost';
const incompatibleHostURI = 'http://$incompatibleHost';
const trailingSlashHostURI = '$goodHostURI/';
// Server behind a reverse proxy which redirects plain HTTP requests to HTTPS
const secureHost = 'secure-polaris-server';
const secureHostURI = 'https://$secureHost';
const insecureHostURI = 'http://$secureHost';

const compatibleAPIVersion = '{"major": 8, "minor": 0}';
const incompatibleAPIVersion = '{"major": 5, "minor": 0}';
const authorization = '{"username": "test-user", "token": "0xDEADBEEF", "is_admin": false}';
const ssoAuthorization = '{"username": "sso-user", "token": "0xC0FFEE", "is_admin": false}';
const ssoProviderName = 'Example SSO';
const ssoLoginURL = '/api/oidc/example/start';
const ssoCode = 'single-use-code';

const rootDirectoryName = 'root';
const heronDirectoryName = 'Heron';
const aegeusDirectoryName = 'Aegeus';
const rootDirectoryPath = rootDirectoryName;
const heronDirectoryPath = '$rootDirectoryName/$heronDirectoryName';
const aegeusDirectoryPath = '$heronDirectoryPath/$aegeusDirectoryName';

const labyrinthSongName = 'Labyrinth';
const fallInwardsSongName = 'Falling Inwards';
const labyrinthFilePath = '$aegeusDirectoryPath/$labyrinthSongName.mp3';
const fallInwardsFilePath = '$aegeusDirectoryPath/$fallInwardsSongName.mp3';

class HttpClient extends mocktail.Mock implements http.Client {
  bool _mockUnauthorized = false;
  bool _mockSSO = false;
  String? _ssoCodeChallenge;
  final List<SSOCodeExchange> ssoCodeExchanges = [];
  Duration? _delay;

  void mockUnauthorized() {
    _mockUnauthorized = true;
  }

  /// Makes the server offer single sign-on, like servers which support it.
  void mockSSO() {
    _mockSSO = true;
  }

  /// What the server remembers from the sign-in started in the browser.
  void setSSOCodeChallenge(String codeChallenge) {
    _ssoCodeChallenge = codeChallenge;
  }

  void setNetworkDelay(Duration delay) {
    _delay = delay;
  }

  HttpClient() {
    mocktail.registerFallbackValue(http.Request("GET", Uri()));

    mocktail.when(() => send(mocktail.any())).thenAnswer((Invocation invocation) async {
      final delay = _delay;
      if (delay != null) {
        await Future<void>.delayed(delay);
      }

      final Request request = invocation.positionalArguments[0];
      final String endpoint = request.url.path;

      if (request.url.host == secureHost && request.url.scheme == 'http') {
        // Like the real HTTP client, only follows redirections of GET requests, and only if asked to
        if (request.method != 'GET' || !request.followRedirects) {
          final location = request.url.replace(scheme: 'https').toString();
          return http.StreamedResponse(Stream<List<int>>.value([]), 308, headers: {'location': location});
        }
      }

      // The API version can be read without being signed in
      if (_mockUnauthorized && !endpoint.startsWith(apiVersionEndpoint)) {
        return http.StreamedResponse(Stream<List<int>>.value([]), 401);
      }

      if (endpoint.startsWith(apiVersionEndpoint)) {
        final String host = request.url.host;
        if (host == goodHost || host == secureHost) {
          return http.StreamedResponse(Stream<List<int>>.value(compatibleAPIVersion.codeUnits), 200);
        }
        if (host == incompatibleHost) {
          return http.StreamedResponse(Stream<List<int>>.value(incompatibleAPIVersion.codeUnits), 200);
        }
        if (host == badHost) {
          return http.StreamedResponse(Stream<List<int>>.value([]), 404);
        }
      } else if (endpoint == ssoProvidersEndpoint && _mockSSO) {
        final providers = [SSOProvider(name: 'example', displayName: ssoProviderName, loginURL: ssoLoginURL)];
        return http.StreamedResponse(Stream<List<int>>.value(utf8.encode(jsonEncode(providers))), 200);
      } else if (endpoint == ssoTokenEndpoint && _mockSSO) {
        final exchange = SSOCodeExchange.fromJson(jsonDecode(request.body));
        ssoCodeExchanges.add(exchange);
        // Like the server, only accepts the code along with the secret behind the challenge
        final isValid = exchange.code == ssoCode && makeCodeChallenge(exchange.codeVerifier) == _ssoCodeChallenge;
        _ssoCodeChallenge = null;
        if (!isValid) {
          return http.StreamedResponse(Stream<List<int>>.value([]), 400);
        }
        return http.StreamedResponse(Stream<List<int>>.value(ssoAuthorization.codeUnits), 200);
      } else if (endpoint.startsWith(loginEndpoint)) {
        return http.StreamedResponse(Stream<List<int>>.value(authorization.codeUnits), 200);
      } else if (endpoint.startsWith(browseEndpoint)) {
        final String path = Uri.decodeComponent(endpoint.substring(browseEndpoint.length));
        final List<BrowserEntry>? files = _browseData[path];
        if (files != null) {
          final String payload = jsonEncode(files);
          return http.StreamedResponse(Stream<List<int>>.value(payload.codeUnits), 200);
        }
      } else if (endpoint.startsWith(songsEndpoint)) {
        final songBatch = SongBatchRequest.fromJson(jsonDecode(request.body));
        final songs = SongBatch(songs: [], notFound: songBatch.paths);
        final String payload = jsonEncode(songs);
        return http.StreamedResponse(Stream<List<int>>.value(payload.codeUnits), 200);
      }
      return http.StreamedResponse(Stream<List<int>>.value([]), 404);
    });
  }
}

Map<String, List<BrowserEntry>> _browseData = {
  '': [
    BrowserEntry(path: rootDirectoryPath, isDirectory: true),
  ],
  rootDirectoryPath: [
    BrowserEntry(path: heronDirectoryPath, isDirectory: true),
  ],
  heronDirectoryPath: [
    BrowserEntry(path: aegeusDirectoryPath, isDirectory: true),
  ],
  aegeusDirectoryPath: [
    BrowserEntry(path: labyrinthFilePath, isDirectory: false),
    BrowserEntry(path: fallInwardsFilePath, isDirectory: false),
  ],
};
