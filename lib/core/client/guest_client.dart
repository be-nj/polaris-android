import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:polaris/core/client/api/api_client.dart';
import 'package:polaris/core/client/api/v8_dto.dart' as dto;
import 'package:polaris/core/client/base_http.dart';
import 'package:polaris/core/connection.dart' as connection;

const apiVersionEndpoint = '/api/version/';
const browseEndpoint = '/api/browse/';
const loginEndpoint = '/api/auth/';
const ssoProvidersEndpoint = '/api/oidc/providers';
const ssoTokenEndpoint = '/api/oidc/token';

class GuestClient extends BaseHttpClient {
  GuestClient({
    required http.Client httpClient,
    required connection.Manager connectionManager,
  }) : super(httpClient: httpClient, connectionManager: connectionManager);

  Future<dto.APIVersion> getAPIVersion() async {
    final url = makeURL(apiVersionEndpoint);
    final responseBody = await completeRequest(Method.get, url, timeout: const Duration(seconds: 5));
    try {
      String body = utf8.decode(responseBody);
      return dto.APIVersion.fromJson(jsonDecode(body));
    } catch (e) {
      throw APIError.responseParseError;
    }
  }

  Future<dto.Authorization> login(String username, String password) async {
    final url = makeURL(loginEndpoint);
    final credentials = dto.Credentials(username: username, password: password).toJson();
    final responseBody = await completeRequest(Method.post, url, body: credentials);
    try {
      return dto.Authorization.fromJson(jsonDecode(utf8.decode(responseBody)));
    } catch (e) {
      throw APIError.responseParseError;
    }
  }

  /// Lists the single sign-on providers users can sign in with.
  /// Servers without support for single sign-on do not have this endpoint.
  Future<List<dto.SSOProvider>> getSSOProviders() async {
    final url = makeURL(ssoProvidersEndpoint);
    final responseBody = await completeRequest(Method.get, url, timeout: const Duration(seconds: 5));
    try {
      final providers = jsonDecode(utf8.decode(responseBody)) as List<dynamic>;
      return providers.map((p) => dto.SSOProvider.fromJson(p)).toList();
    } catch (e) {
      throw APIError.responseParseError;
    }
  }

  /// Exchanges the code received at the end of a single sign-on for a session.
  Future<dto.Authorization> redeemSSOCode(String code, String codeVerifier) async {
    final url = makeURL(ssoTokenEndpoint);
    final exchange = dto.SSOCodeExchange(code: code, codeVerifier: codeVerifier).toJson();
    final responseBody = await completeRequest(Method.post, url, body: exchange);
    try {
      return dto.Authorization.fromJson(jsonDecode(utf8.decode(responseBody)));
    } catch (e) {
      throw APIError.responseParseError;
    }
  }

  Future<void> testConnection(String? authenticationToken) async {
    final url = makeURL(browseEndpoint);
    await makeRequest(Method.get, url, authenticationToken: authenticationToken);
  }
}
