import 'package:flutter/services.dart';

/// Firebase Cloud Messaging on Android without the full Firebase Flutter
/// plugins (which would download Firebase's desktop SDK into every Windows
/// build). The Firebase project is given at runtime, so no
/// google-services.json is needed.
class TunetrailPush {
  static const _ch = MethodChannel('tunetrail/push');

  /// Asks for permission to show notifications (Android 13+). True when
  /// allowed.
  static Future<bool> requestPermission() async => await _ch.invokeMethod<bool>('requestPermission') ?? false;

  /// Starts Firebase for the given project and returns this device's push
  /// token (null if it couldn't get one).
  static Future<String?> token({required String apiKey, required String appId, required String projectId, required String senderId}) =>
      _ch.invokeMethod<String>('token', {'apiKey': apiKey, 'appId': appId, 'projectId': projectId, 'senderId': senderId});
}
