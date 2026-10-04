import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

enum ThemeChoice { system, light, dark }

/// Who is signed in, the tuition name and the theme choice.
class Session extends ChangeNotifier {
  Session._();
  static final instance = Session._();

  static const _storage = FlutterSecureStorage();
  late SharedPreferences _prefs;

  Map<String, dynamic>? user;
  String tuitionName = 'Core Academy';
  ThemeChoice theme = ThemeChoice.system;
  bool restored = false;

  bool get signedIn => api.token != null && user != null;
  bool get isTeacher => user?['role'] == 'teacher';
  String get firstName => '${user?['display_name'] ?? ''}'.trim().split(RegExp(r'\s+')).first;

  Future<void> loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    theme = ThemeChoice.values.firstWhere((t) => t.name == _prefs.getString('theme'), orElse: () => ThemeChoice.system);
    tuitionName = _prefs.getString('tuition_name') ?? 'Core Academy';
  }

  Future<void> restore() async {
    api.onSignedOut = _signedOutByServer;
    api.token = await _storage.read(key: 'token');
    if (api.token != null) {
      final cached = _prefs.getString('user');
      user = cached == null ? null : jsonDecode(cached) as Map<String, dynamic>;
      try {
        await _refreshMe();
      } on ApiException catch (e) {
        if (e.status == 401) await _clear();
        // Offline: keep the cached user so a started test can still be resumed.
      }
    }
    restored = true;
    notifyListeners();
  }

  Future<void> _refreshMe() async {
    final me = await api.get('/auth/me');
    user = Map<String, dynamic>.from(me['user']);
    tuitionName = '${me['tuition_name']}';
    await _prefs.setString('user', jsonEncode(user));
    await _prefs.setString('tuition_name', tuitionName);
  }

  Future<void> login(String username, String secret) async {
    final r = await api.post('/auth/login', {'username': username.trim().toLowerCase(), 'secret': secret});
    api.token = r['token'] as String;
    await _storage.write(key: 'token', value: api.token);
    user = Map<String, dynamic>.from(r['user']);
    try {
      await _refreshMe();
    } on ApiException {
      await _prefs.setString('user', jsonEncode(user));
    }
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await api.post('/auth/logout');
    } catch (_) {}
    await _clear();
    notifyListeners();
  }

  Future<void> _clear() async {
    api.token = null;
    user = null;
    await _storage.delete(key: 'token');
    await _prefs.remove('user');
  }

  void _signedOutByServer() {
    _clear().then((_) => notifyListeners());
  }

  Future<void> setTheme(ThemeChoice t) async {
    theme = t;
    await _prefs.setString('theme', t.name);
    notifyListeners();
  }

  SharedPreferences get prefs => _prefs;
}

final session = Session.instance;
