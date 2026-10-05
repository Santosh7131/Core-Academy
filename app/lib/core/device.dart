import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the app tells the server about itself on every request (from 1.2.1), so the developer's
/// admin app can show each account's phones and the version they run. Nothing personal: a random
/// id made up on first launch, the phone's maker and model, the Android version, the app version.
class Device {
  Device._();

  static final headers = <String, String>{};

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
    } catch (_) {
      // Without storage the requests just go without an id, as from older versions.
    }
    try {
      final info = await const MethodChannel('core_academy/updater').invokeMapMethod<String, dynamic>('info');
      if (info?['version'] != null) headers['x-app'] = 'core_academy/${info!['version']}+${info['build']}';
      if (info?['model'] != null) headers['x-device'] = '${info!['model']}';
      if (info?['os'] != null) headers['x-os'] = '${info!['os']}';
    } on PlatformException {
      // Not on a phone build: no details to send.
    }
  }
}
