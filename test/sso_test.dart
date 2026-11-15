import 'harness.dart';
import 'mock/http_client.dart' as client;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:polaris/core/authentication.dart' as authentication;
import 'package:polaris/core/connection.dart' as connection;
import 'package:polaris/core/sso.dart' as sso;
import 'package:polaris/main.dart';
import 'package:polaris/ui/startup/page.dart';
import 'package:polaris/ui/strings.dart';
import 'package:shared_preferences/shared_preferences.dart';

final startupPage = find.byType(StartupPage);
final loginButton = find.widgetWithText(ElevatedButton, loginButtonLabel);
final ssoButton = find.widgetWithText(OutlinedButton, ssoButtonLabel(client.ssoProviderName));

const connectedPreferences = {connection.hostPreferenceKey: client.goodHostURI};

Future<Harness> openLoginScreen(
  WidgetTester tester, {
  bool serverSupportsSSO = true,
  Map<String, Object> preferences = connectedPreferences,
}) async {
  final harness = await Harness.create(preferences: preferences);
  if (serverSupportsSSO) {
    harness.mockHTTPClient.mockSSO();
  }
  await tester.pumpWidget(const PolarisApp());
  await tester.pumpAndSettle();
  return harness;
}

/// Taps the single sign-on button, which opens the web browser. Like the real server, the mock server
/// remembers the code challenge the app sent along.
Future<void> startSignIn(WidgetTester tester, Harness harness) async {
  await tester.tap(ssoButton);
  await tester.pump();
  harness.mockHTTPClient.setSSOCodeChallenge(harness.mockBrowser.codeChallenge!);
}

void main() {
  test('Code challenges are SHA-256 hashes of code verifiers', () {
    // Example from RFC 7636, appendix B
    expect(
      sso.makeCodeChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      equals('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'),
    );
  });

  test('Code verifiers are random', () {
    final verifiers = List.generate(100, (_) => sso.makeCodeVerifier());
    expect(verifiers.toSet().length, equals(verifiers.length));
    for (final verifier in verifiers) {
      expect(verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
    }
  });

  test('Only reads codes from links meant for this app', () {
    expect(sso.readCode('polaris://sso?code=abc'), equals('abc'));
    expect(sso.readCode('polaris://sso?code=a%2Fb&other=c'), equals('a/b'));
    expect(sso.readCode('polaris://sso'), isNull);
    expect(sso.readCode('polaris://sso?code='), isNull);
    expect(sso.readCode('polaris://elsewhere?code=abc'), isNull);
    expect(sso.readCode('https://sso?code=abc'), isNull);
    expect(sso.readCode('https://example.com/?code=abc'), isNull);
    expect(sso.readCode(''), isNull);
  });

  testWidgets('Login screen does not offer single sign-on when the server has none', (WidgetTester tester) async {
    await openLoginScreen(tester, serverSupportsSSO: false);
    expect(loginButton, findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('Login screen offers the single sign-on providers of the server', (WidgetTester tester) async {
    await openLoginScreen(tester);
    expect(loginButton, findsOneWidget);
    expect(ssoButton, findsOneWidget);
  });

  testWidgets('Single sign-on golden path', (WidgetTester tester) async {
    final harness = await openLoginScreen(tester);
    await startSignIn(tester, harness);

    // The browser is sent to the sign-in page of the server, with a code challenge
    expect(harness.mockBrowser.visitedURLs.length, equals(1));
    final visitedURL = Uri.parse(harness.mockBrowser.visitedURLs.single);
    expect(visitedURL.origin, equals(client.goodHostURI));
    expect(visitedURL.path, equals(client.ssoLoginURL));
    expect(visitedURL.queryParameters.keys, equals(['code_challenge']));
    expect(harness.mockBrowser.codeChallenge, matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));

    // No requests are made while the user is busy in the browser
    expect(harness.mockHTTPClient.ssoCodeExchanges, isEmpty);
    expect(startupPage, findsOneWidget);

    harness.mockBrowser.completeSignIn('polaris://sso?code=${client.ssoCode}');
    await tester.pumpAndSettle();
    expect(startupPage, findsNothing);

    // The code was redeemed with the secret behind the code challenge, which the browser never saw
    final exchange = harness.mockHTTPClient.ssoCodeExchanges.single;
    expect(exchange.code, equals(client.ssoCode));
    expect(sso.makeCodeChallenge(exchange.codeVerifier), equals(harness.mockBrowser.codeChallenge));
    expect(harness.mockBrowser.visitedURLs.single, isNot(contains(exchange.codeVerifier)));

    // The session is remembered like one obtained with a password
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(authentication.tokenPreferenceKey), equals('0xC0FFEE'));
    expect(preferences.getString(authentication.usernamePreferenceKey), equals('sso-user'));
    expect(preferences.getString(authentication.authHostPreferenceKey), equals(client.goodHostURI));
  });

  testWidgets('Leaving the browser returns to the login screen', (WidgetTester tester) async {
    final harness = await openLoginScreen(tester);
    await startSignIn(tester, harness);
    expect(ssoButton, findsNothing);

    harness.mockBrowser.cancelSignIn();
    await tester.pumpAndSettle();

    expect(startupPage, findsOneWidget);
    expect(ssoButton, findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(harness.mockHTTPClient.ssoCodeExchanges, isEmpty);

    // Signing in can be attempted again, with a different secret
    final firstChallenge = harness.mockBrowser.codeChallenge;
    await startSignIn(tester, harness);
    expect(harness.mockBrowser.codeChallenge, isNot(equals(firstChallenge)));
    harness.mockBrowser.completeSignIn('polaris://sso?code=${client.ssoCode}');
    await tester.pumpAndSettle();
    expect(startupPage, findsNothing);
  });

  testWidgets('Rejects links which do not carry a code', (WidgetTester tester) async {
    final harness = await openLoginScreen(tester);
    for (final callbackURL in ['polaris://sso', 'polaris://elsewhere?code=${client.ssoCode}', 'not a link']) {
      await startSignIn(tester, harness);
      harness.mockBrowser.completeSignIn(callbackURL);
      await tester.pump();
      expect(find.textContaining(errorSSOFailed), findsOneWidget, reason: callbackURL);
      expect(find.textContaining('unexpected link'), findsOneWidget, reason: callbackURL);
      // The message does not disclose the code
      expect(find.textContaining(client.ssoCode), findsNothing, reason: callbackURL);
      expect(ssoButton, findsOneWidget, reason: callbackURL);
      expect(harness.mockHTTPClient.ssoCodeExchanges, isEmpty, reason: callbackURL);
    }
  });

  testWidgets('Reports errors of the web browser', (WidgetTester tester) async {
    final harness = await openLoginScreen(tester);
    await startSignIn(tester, harness);

    harness.mockBrowser.failSignIn(PlatformException(code: 'FAILED', message: 'Authentication failed with code: 2'));
    await tester.pump();

    expect(find.textContaining('the web browser reported an error: FAILED, Authentication failed with code: 2'),
        findsOneWidget);
    expect(ssoButton, findsOneWidget);
    expect(harness.mockHTTPClient.ssoCodeExchanges, isEmpty);
  });

  testWidgets('Signs in with servers which redirect to HTTPS', (WidgetTester tester) async {
    // The user typed the address of the server without `https://`, which the server redirects to
    final harness = await openLoginScreen(tester, preferences: {connection.hostPreferenceKey: client.insecureHostURI});
    await startSignIn(tester, harness);
    expect(Uri.parse(harness.mockBrowser.visitedURLs.single).origin, equals(client.secureHostURI));

    harness.mockBrowser.completeSignIn('polaris://sso?code=${client.ssoCode}');
    await tester.pumpAndSettle();
    expect(startupPage, findsNothing);

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(authentication.tokenPreferenceKey), equals('0xC0FFEE'));
    expect(preferences.getString(authentication.authHostPreferenceKey), equals(client.secureHostURI));
  });

  testWidgets('Reports codes the server does not accept', (WidgetTester tester) async {
    final harness = await openLoginScreen(tester);
    await startSignIn(tester, harness);

    harness.mockBrowser.completeSignIn('polaris://sso?code=made-up-code');
    await tester.pump();
    await tester.pump();

    expect(harness.mockHTTPClient.ssoCodeExchanges.length, equals(1));
    expect(find.textContaining('$errorSSOFailed: the server did not accept the sign-in'), findsOneWidget);
    expect(startupPage, findsOneWidget);
    expect(ssoButton, findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(authentication.tokenPreferenceKey), isNull);
  });
}
