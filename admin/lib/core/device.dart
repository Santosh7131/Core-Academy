import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the admin app tells the server about itself on every request: a random id made up on
/// first launch, the phone's maker and model, the Android version and the app version.
class Device {
  Device._();

  static final headers = <String, String>{};
  static String? version;
  static int build = 0;

  static Future<void> load() async {
    if (!Platform.isAndroid) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      var id = prefs.getString('install_id');
      if (id == null) {
        final r = Random.secure();
        id = List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        await prefs.setString('install_id', id);
      }
      headers['x-install-id'] = id;
    } catch (_) {}
    try {
      final info = await const MethodChannel('core_academy/updater').invokeMapMethod<String, dynamic>('info');
      version = info?['version'] as String?;
      build = (info?['build'] as num?)?.toInt() ?? 0;
      if (version != null) headers['x-app'] = 'admin/$version+$build';
      if (info?['model'] != null) headers['x-device'] = '${info!['model']}';
      if (info?['os'] != null) headers['x-os'] = '${info!['os']}';
    } on PlatformException {
      // Not on a phone build.
    }
  }
}
