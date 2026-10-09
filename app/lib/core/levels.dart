import 'session.dart';

/// A class or level. Class 1 to 12 are the numbers 1 to 12. A level a tuition named itself ("LKG",
/// "NEET 2027") is 101 or more, and the server keeps its name (api/src/lib/levels.ts).
class Level {
  const Level(this.code, this.label, {this.custom = false});
  final int code;
  final String label;
  final bool custom;
}

const firstNamedLevel = 101;

/// Class 1 to 12, then the levels the tuition on screen named itself, then [extra]: names a new
/// tuition has typed that the server does not know yet.
List<Level> levelsFor({Map<int, String> extra = const {}}) => [
      for (var i = 1; i <= 12; i++) Level(i, 'Class $i'),
      for (final l in session.customLevels) Level((l['code'] as num).toInt(), '${l['label']}', custom: true),
      for (final e in extra.entries) Level(e.key, e.value, custom: true),
    ];

/// What a tuition calls a class: "Class 9", or the name it gave a level of its own. Reads the
/// tuition on screen unless [tuition] (one entry of `session.tuitions`) is given.
String className(Object? code, {Map<int, String> extra = const {}, Map<String, dynamic>? tuition}) {
  final n = code is num ? code.toInt() : int.tryParse('$code');
  if (n == null) return '';
  if (n < firstNamedLevel) return 'Class $n';
  final named = (tuition?['levels'] as List?) ?? session.customLevels;
  for (final l in named) {
    if ((l as Map)['code'] == n) return '${l['label']}';
  }
  return extra[n] ?? 'Level $n';
}

/// 1st, 2nd, 3rd, 4th ... 11th, 12th.
String ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd', _ => '${n}th' };
}

/// A group is a class and a subject: "10th Science", "1st Maths", "NEET 2027 Physics".
String groupName(int level, String subject, {Map<int, String> extra = const {}, Map<String, dynamic>? tuition}) =>
    level < firstNamedLevel ? '${ordinal(level)} $subject' : '${className(level, extra: extra, tuition: tuition)} $subject';
