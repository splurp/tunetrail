import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// OAuth client ids, set at build time with --dart-define (see
/// docs/multiplayer-setup.md):
///   GOOGLE_SERVER_CLIENT_ID     the "Web application" client (Android/iOS
///                               sign-in tokens are issued for it)
///   GOOGLE_IOS_CLIENT_ID        the iOS client (iOS only)
///   GOOGLE_DESKTOP_CLIENT_ID    the "Desktop app" client (Windows/Linux)
///   GOOGLE_DESKTOP_CLIENT_SECRET  its secret (not confidential for desktop
///                               apps, per Google's docs)
const _serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
const _iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
const _desktopClientId = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID');
const _desktopClientSecret = String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET');

/// Signs the player in with Google and returns a Google ID token for the
/// game server to verify.
class GoogleAuth {
  static bool get _desktop => !kIsWeb && (Platform.isWindows || Platform.isLinux);

  /// Whether this build was configured for Google sign-in on this platform.
  static bool get available => _desktop ? _desktopClientId.isNotEmpty : _serverClientId.isNotEmpty;

  static bool _initialized = false;

  static Future<String> idToken() async {
    if (!available) throw StateError('Google sign-in isn\'t configured in this build');
    return _desktop ? _desktopFlow() : _mobileFlow();
  }

  static Future<String> _mobileFlow() async {
    final g = GoogleSignIn.instance;
    if (!_initialized) {
      await g.initialize(clientId: _iosClientId.isEmpty ? null : _iosClientId, serverClientId: _serverClientId);
      _initialized = true;
    }
    final account = await g.authenticate();
    final token = account.authentication.idToken;
    if (token == null) throw StateError('Google didn\'t return a sign-in token');
    return token;
  }

  static Future<void> signOut() async {
    if (_desktop || !_initialized) return;
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }

  /// Desktop: the browser-based OAuth flow for installed apps (loopback
  /// redirect + PKCE).
  static Future<String> _desktopFlow() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}';
      final rnd = math.Random.secure();
      final verifier = base64Url.encode(List.generate(48, (_) => rnd.nextInt(256))).replaceAll('=', '');
      final challenge = base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
      final state = base64Url.encode(List.generate(16, (_) => rnd.nextInt(256))).replaceAll('=', '');
      final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': _desktopClientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': 'openid profile',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'prompt': 'select_account',
      });
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) throw StateError('Couldn\'t open the browser');
      final req = await server.first.timeout(const Duration(minutes: 5));
      final q = req.uri.queryParameters;
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body style="font-family:sans-serif;background:#111;color:#eee;text-align:center;padding-top:80px">'
            '<h2>Signed in to Tunetrail</h2><p>You can close this tab and return to the game.</p></body></html>');
      await req.response.close();
      if (q['state'] != state) throw StateError('Sign-in was interrupted');
      final code = q['code'];
      if (code == null) throw StateError(q['error'] == 'access_denied' ? 'Sign-in cancelled' : 'Sign-in failed');
      final res = await http.post(Uri.https('oauth2.googleapis.com', '/token'), body: {
        'code': code,
        'client_id': _desktopClientId,
        'client_secret': _desktopClientSecret,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
        'code_verifier': verifier,
      }).timeout(const Duration(seconds: 15));
      final token = (jsonDecode(res.body) as Map<String, dynamic>)['id_token'] as String?;
      if (res.statusCode != 200 || token == null) throw StateError('Google sign-in failed (${res.statusCode})');
      return token;
    } finally {
      await server.close(force: true);
    }
  }
}
