import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';

/// Sends push notifications through Firebase Cloud Messaging (HTTP v1),
/// signed in with a Firebase service account.
class PushSender {
  PushSender._(this._projectId, this._client);
  final String _projectId;
  final AutoRefreshingAuthClient _client;

  /// From the service-account JSON (base64 in FIREBASE_SERVICE_ACCOUNT_B64),
  /// or null when push isn't configured.
  static Future<PushSender?> fromBase64(String? b64) async {
    if (b64 == null || b64.trim().isEmpty) return null;
    final json = jsonDecode(utf8.decode(base64.decode(b64.trim()))) as Map<String, dynamic>;
    final client = await clientViaServiceAccount(ServiceAccountCredentials.fromJson(json), ['https://www.googleapis.com/auth/firebase.messaging']);
    return PushSender._(json['project_id'] as String, client);
  }

  /// Sends one notification; returns false when the token is no longer
  /// valid (so the caller can forget it).
  Future<bool> send(String token, String title, String body) async {
    final res = await _client
        .post(
          Uri.parse('https://fcm.googleapis.com/v1/projects/$_projectId/messages:send'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'message': {
              'token': token,
              'notification': {'title': title, 'body': body},
              'android': {
                'priority': 'high',
                'notification': {'tag': title},
              },
            },
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (res.statusCode == 404 || (res.statusCode == 400 && res.body.contains('INVALID_ARGUMENT') && res.body.contains('token'))) return false;
    return true;
  }

  void close() => _client.close();
}
