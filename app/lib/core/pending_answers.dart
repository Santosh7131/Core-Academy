import 'dart:convert';

import 'session.dart';

/// Answers chosen on the phone but not yet confirmed by the server, kept per attempt
/// so a dropped connection or a killed app never loses them.
class PendingAnswers {
  static String _key(String attemptId) => 'pending:$attemptId';

  static Map<String, Map<String, dynamic>> load(String attemptId) {
    final raw = session.prefs.getString(_key(attemptId));
    if (raw == null) return {};
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return m.map((k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
  }

  static Future<void> save(String attemptId, Map<String, Map<String, dynamic>> pending) async {
    if (pending.isEmpty) {
      await session.prefs.remove(_key(attemptId));
    } else {
      await session.prefs.setString(_key(attemptId), jsonEncode(pending));
    }
  }

  static Future<void> clear(String attemptId) => session.prefs.remove(_key(attemptId));
}
