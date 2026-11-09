import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tunetrail_push/tunetrail_push.dart';

/// Push notifications (Android, Firebase Cloud Messaging). The Firebase
/// project is built in with --dart-define (see docs/multiplayer-setup.md);
/// without it this does nothing.
class PushService {
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');

  static bool get available =>
      !kIsWeb && Platform.isAndroid && _apiKey.isNotEmpty && _appId.isNotEmpty && _projectId.isNotEmpty && _senderId.isNotEmpty;

  /// Asks for permission and returns this device's push token, or null.
  static Future<String?> token() async {
    if (!available) return null;
    try {
      await TunetrailPush.requestPermission();
      return await TunetrailPush.token(apiKey: _apiKey, appId: _appId, projectId: _projectId, senderId: _senderId);
    } catch (e) {
      debugPrint('push: $e');
      return null;
    }
  }
}
