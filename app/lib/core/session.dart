import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'brand.dart';
import 'changes.dart';

enum ThemeChoice { system, light, dark }

/// Who is signed in, the tuitions they are in, the tuition on screen and the theme choice.
class Session extends ChangeNotifier {
  Session._();
  static final instance = Session._();

  static const _storage = FlutterSecureStorage();
  late SharedPreferences _prefs;

  Map<String, dynamic>? user;
  String tuitionName = appName;
  ThemeChoice theme = ThemeChoice.system;
  bool restored = false;

  /// The opening animation has played (or was skipped). The router leaves the start screen once this and [restored] are both true.
  bool splashDone = false;

  /// The tuitions the person is in or waiting to join: {id, name, role, status, class_level, join_code?}.
  List<Map<String, dynamic>> tuitions = [];

  /// The tuition on screen: one of the active ones. Sent with every request.
  String? tuitionId;

  bool get signedIn => api.token != null && user != null;
  bool get isTeacher => user?['role'] == 'teacher';
  String get firstName => '${user?['display_name'] ?? ''}'.trim().split(RegExp(r'\s+')).first;

  Iterable<Map<String, dynamic>> get activeTuitions => tuitions.where((t) => t['status'] == 'active');
  Iterable<Map<String, dynamic>> get pendingTuitions => tuitions.where((t) => t['status'] == 'pending');

  Map<String, dynamic>? get activeTuition {
    for (final t in activeTuitions) {
      if (t['id'] == tuitionId) return t;
    }
    return activeTuitions.firstOrNull;
  }

  /// The levels the tuition on screen named itself ("LKG", "NEET 2027"): [{code, label}]. Class 1 to 12 need no list.
  List<Map<String, dynamic>> get customLevels => [for (final l in (activeTuition?['levels'] as List? ?? const [])) Map<String, dynamic>.from(l as Map)];

  /// A tutor with no tuition yet creates one; a student with no place yet joins one.
  bool get needsTuition => signedIn && activeTuitions.isEmpty;

  /// A person in more than one tuition chooses which one the app shows.
  bool get hasChoice => activeTuitions.length > 1;

  /// The student's class in the tuition on screen (their class can differ from tuition to tuition).
  int? get classLevel => (activeTuition?['class_level'] as num?)?.toInt() ?? (user?['class_level'] as num?)?.toInt();

  String get _tuitionKey => 'tuition:${user?['id']}';

  Future<void> loadPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    theme = ThemeChoice.values.firstWhere((t) => t.name == _prefs.getString('theme'), orElse: () => ThemeChoice.system);
    tuitionName = _prefs.getString('tuition_name') ?? appName;
  }

  Future<void> restore() async {
    api.onSignedOut = _signedOutByServer;
    api.onTuitionGone = _tuitionGone;
    api.token = await _storage.read(key: 'token');
    if (api.token != null) {
      final cached = _prefs.getString('user');
      user = cached == null ? null : jsonDecode(cached) as Map<String, dynamic>;
      // What the phone last knew, so an offline start still shows the right screens.
      final saved = _prefs.getString('tuitions');
      if (saved != null) _applyTuitions(jsonDecode(saved));
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

  /// Takes the server's list of the person's tuitions and keeps the chosen one if it is still theirs.
  void _applyTuitions(Object? raw) {
    tuitions = [for (final t in (raw as List? ?? const [])) Map<String, dynamic>.from(t as Map)];
    final saved = _prefs.getString(_tuitionKey);
    final active = activeTuitions.toList();
    final wanted = tuitionId ?? saved;
    final pick = active.where((t) => t['id'] == wanted).firstOrNull ?? active.firstOrNull;
    tuitionId = pick?['id'] as String?;
    api.tuitionId = tuitionId;
    if (pick != null) tuitionName = '${pick['name']}';
  }

  Future<void> _refreshMe() async {
    final me = await api.get('/auth/me');
    user = Map<String, dynamic>.from(me['user']);
    _applyTuitions(me['tuitions']);
    if (tuitionId == null) tuitionName = '${me['tuition_name']}';
    await _prefs.setString('user', jsonEncode(user));
    await _prefs.setString('tuition_name', tuitionName);
    await _prefs.setString('tuitions', jsonEncode(tuitions));
    if (tuitionId != null) await _prefs.setString(_tuitionKey, tuitionId!);
  }

  /// Loads the person's tuitions again (a request to join was answered, or one was added).
  Future<void> refreshTuitions() async {
    try {
      await _refreshMe();
    } on ApiException catch (e) {
      if (e.status == 401) await _clear();
    }
    notifyListeners();
  }

  /// Tells listeners something this class holds was changed from outside (the router checks it again).
  void changed() => notifyListeners();

  void finishSplash() {
    if (splashDone) return;
    splashDone = true;
    notifyListeners();
  }

  Future<void> login(String username, String secret) async {
    final r = await api.post('/auth/login', {'username': username.trim().toLowerCase(), 'secret': secret});
    if (r['user']?['role'] == 'developer') {
      // The developer's login is for the admin app; leave no session behind in this one.
      api.token = r['token'] as String;
      try {
        await api.post('/auth/logout');
      } catch (_) {}
      api.token = null;
      throw ApiException(403, 'admin_app', 'This login is for the Core Academy Admin app.');
    }
    await _signedIn(r);
  }

  /// A tutor makes their own login. They have no tuition yet: [createTuition] comes next.
  Future<void> signUpTutor({required String name, required String username, required String password}) async {
    final r = await api.post('/auth/signup-tutor', {'display_name': name.trim(), 'username': username.trim().toLowerCase(), 'password': password});
    await _signedIn(r);
  }

  Future<void> _signedIn(dynamic r) async {
    api.token = r['token'] as String;
    await _storage.write(key: 'token', value: api.token);
    user = Map<String, dynamic>.from(r['user']);
    tuitionId = null;
    _applyTuitions(r['tuitions']);
    try {
      await _refreshMe();
    } on ApiException {
      await _prefs.setString('user', jsonEncode(user));
      await _prefs.setString('tuitions', jsonEncode(tuitions));
    }
    notifyListeners();
  }

  /// Creates the signed-in tutor's tuition with the groups they teach: [{class_level, subject_id | subject_name}].
  /// Does not notify: the screen moves on first, so the router does not send the tutor home before
  /// they have seen their join code. Call [changed] after.
  Future<Map<String, dynamic>> createTuition(String name, List<Map<String, dynamic>> groups) async {
    final r = await api.post('/auth/tuitions', {'name': name.trim(), 'groups': groups});
    await _refreshMe();
    return Map<String, dynamic>.from(r['tuition']);
  }

  /// A student asks to join a tuition with its code: {tuition: {id, name}, status: 'pending'}. A tutor
  /// has to let them in.
  Future<Map<String, dynamic>> joinTuition(String code) async {
    final r = await api.post('/student/join', {'code': code});
    await _refreshMe();
    notifyListeners();
    return Map<String, dynamic>.from(r);
  }

  /// Shows another of the person's active tuitions. Every screen loads again.
  void switchTuition(String id) {
    if (id == tuitionId || !activeTuitions.any((t) => t['id'] == id)) return;
    tuitionId = id;
    api.tuitionId = id;
    tuitionName = '${activeTuitions.firstWhere((t) => t['id'] == id)['name']}';
    _prefs.setString(_tuitionKey, id);
    _prefs.setString('tuition_name', tuitionName);
    notifyListeners();
    changes.reportAreas(Area.values.toSet());
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
    api.tuitionId = null;
    user = null;
    tuitions = [];
    tuitionId = null;
    await _storage.delete(key: 'token');
    await _prefs.remove('user');
    await _prefs.remove('tuitions');
  }

  void _signedOutByServer() {
    _clear().then((_) => notifyListeners());
  }

  /// The server says the person is not in the tuition on screen any more: look at what they have now.
  void _tuitionGone() {
    tuitionId = null;
    api.tuitionId = null;
    refreshTuitions().then((_) => changes.reportAreas(Area.values.toSet()));
  }

  Future<void> setTheme(ThemeChoice t) async {
    theme = t;
    await _prefs.setString('theme', t.name);
    notifyListeners();
  }

  SharedPreferences get prefs => _prefs;
}

final session = Session.instance;
