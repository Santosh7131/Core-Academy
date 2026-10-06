import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

enum ThemeChoice { system, light, dark }

/// The developer's login and the theme.
class Session extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  late SharedPreferences _prefs;
  Map<String, dynamic>? user;
  ThemeChoice theme = ThemeChoice.system;
  bool restored = false;

  bool get signedIn => api.token != null && user != null;

  static const _tokenKey = 'token';
  static const _userKey = 'user';

  /// Read before the first frame: the theme.
  Future<void> loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    theme = ThemeChoice.values.firstWhere((t) => t.name == _prefs.getString('theme'), orElse: () => ThemeChoice.system);
  }

  Future<void> restore() async {
    api.onSignedOut = () => _clear().then((_) => notifyListeners());
    await _carryOver();
    await _load();
    restored = true;
    notifyListeners();
  }

  /// Up to 1.0.1 the app kept one login per database, live and dev. The one this build reads
  /// carries over; the other is forgotten.
  Future<void> _carryOver() async {
    if (!_prefs.containsKey('env') && !_prefs.containsKey('user_live') && !_prefs.containsKey('user_dev')) return;
    final from = kReleaseMode ? 'live' : 'dev';
    final token = await _storage.read(key: 'token_$from');
    final cached = _prefs.getString('user_$from');
    if (token != null && cached != null) {
      await _storage.write(key: _tokenKey, value: token);
      await _prefs.setString(_userKey, cached);
    }
    for (final k in ['token_live', 'token_dev']) {
      await _storage.delete(key: k);
    }
    for (final k in ['user_live', 'user_dev', 'env']) {
      await _prefs.remove(k);
    }
  }

  Future<void> _load() async {
    api.token = await _storage.read(key: _tokenKey);
    final cached = _prefs.getString(_userKey);
    user = api.token == null || cached == null ? null : jsonDecode(cached) as Map<String, dynamic>;
    if (api.token == null) return;
    try {
      final me = await api.get('/auth/me');
      user = Map<String, dynamic>.from(me['user']);
      if (user?['role'] != 'developer') {
        await _clear();
      } else {
        await _prefs.setString(_userKey, jsonEncode(user));
      }
    } on ApiException catch (e) {
      if (e.status == 401 || e.status == 403) await _clear();
      // Offline: keep the cached login; each screen shows its own error.
    }
  }

  Future<void> setTheme(ThemeChoice t) async {
    theme = t;
    await _prefs.setString('theme', t.name);
    notifyListeners();
  }

  Future<void> login(String username, String password) async {
    final r = await api.post('/auth/login', {'username': username.trim().toLowerCase(), 'secret': password});
    if (r['user']?['role'] != 'developer') {
      // A teacher or student login: leave no session behind, and say why.
      api.token = r['token'] as String;
      try {
        await api.post('/auth/logout');
      } catch (_) {}
      api.token = null;
      throw ApiException(403, 'not_developer', 'This app only takes the developer login. Teachers and students use Core Academy.');
    }
    api.token = r['token'] as String;
    user = Map<String, dynamic>.from(r['user']);
    await _storage.write(key: _tokenKey, value: api.token);
    await _prefs.setString(_userKey, jsonEncode(user));
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
    await _storage.delete(key: _tokenKey);
    await _prefs.remove(_userKey);
  }
}

final session = Session();
