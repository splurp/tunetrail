import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Sign-in: verifies Google ID tokens and issues the server's own signed
/// session tokens (so Google is only contacted once per sign-in).
class Auth {
  Auth({required String secret, required this.googleClientIds, required this.allowGuests, http.Client? client})
      : _key = utf8.encode(secret),
        _client = client ?? http.Client();

  final List<int> _key;
  final Set<String> googleClientIds;

  /// Accept unauthenticated `X-Player-Id` players (development, and
  /// desktop builds until they have Google sign-in).
  final bool allowGuests;
  final http.Client _client;

  static const sessionDays = 60;

  /// Checks a Google ID token with Google's tokeninfo endpoint and returns
  /// (player id, display name).
  Future<(String, String)> verifyGoogle(String idToken) async {
    final res = await _client.get(Uri.https('oauth2.googleapis.com', '/tokeninfo', {'id_token': idToken})).timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) throw AuthException('Google rejected the sign-in token');
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final aud = j['aud'] as String? ?? '';
    final iss = j['iss'] as String? ?? '';
    final exp = int.tryParse('${j['exp']}') ?? 0;
    if (!googleClientIds.contains(aud)) throw AuthException('Token was issued for another app');
    if (iss != 'accounts.google.com' && iss != 'https://accounts.google.com') throw AuthException('Bad token issuer');
    if (exp * 1000 < DateTime.now().millisecondsSinceEpoch) throw AuthException('Sign-in token expired');
    final sub = j['sub'] as String?;
    if (sub == null || sub.isEmpty) throw AuthException('No account id in token');
    final name = (j['given_name'] ?? j['name'] ?? 'Player') as String;
    return ('g_$sub', name);
  }

  String _sign(String payload) => base64Url.encode(Hmac(sha256, _key).convert(utf8.encode(payload)).bytes).replaceAll('=', '');

  /// A session token for [playerId] (valid [sessionDays] days).
  String issue(String playerId, String name) {
    final exp = DateTime.now().add(const Duration(days: sessionDays)).millisecondsSinceEpoch;
    final payload = base64Url.encode(utf8.encode(jsonEncode({'id': playerId, 'name': name, 'exp': exp}))).replaceAll('=', '');
    return '$payload.${_sign(payload)}';
  }

  /// (player id, name) for a valid session token, else null.
  (String, String)? check(String token) {
    final dot = token.indexOf('.');
    if (dot <= 0) return null;
    final payload = token.substring(0, dot), sig = token.substring(dot + 1);
    if (!_equal(sig, _sign(payload))) return null;
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(payload)))) as Map<String, dynamic>;
      if ((j['exp'] as num).toInt() < DateTime.now().millisecondsSinceEpoch) return null;
      return (j['id'] as String, j['name'] as String? ?? 'Player');
    } catch (_) {
      return null;
    }
  }

  static bool _equal(String a, String b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return d == 0;
  }
}

class AuthException implements Exception {
  AuthException(this.message);
  final String message;
  @override
  String toString() => message;
}
