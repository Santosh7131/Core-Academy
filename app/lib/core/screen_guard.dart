import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Blocks screenshots and screen recording while a student is logged in, so test questions
/// and answers cannot be captured and passed around. The teacher's screens stay open to
/// screenshots. A photo of the screen taken with another phone cannot be stopped.
///
/// On in release builds. Debug builds leave it off so the test phone can take screenshots;
/// build with --dart-define=SECURE_SCREENS=true to try it there.
class ScreenGuard {
  static const _enabled = bool.fromEnvironment('SECURE_SCREENS', defaultValue: kReleaseMode);
  static const _channel = MethodChannel('core_academy/screen');
  static bool? _on;

  static Future<void> forRole(String? role) async {
    final on = _enabled && role == 'student';
    if (_on == on) return;
    _on = on;
    try {
      await _channel.invokeMethod<void>('setSecure', on);
    } on MissingPluginException {
      // Unit tests and platforms without the channel.
    } on PlatformException {
      // Never let screen protection stop the app from working.
    }
  }
}
