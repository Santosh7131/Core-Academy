import 'package:intl/intl.dart';

DateTime? parseTime(dynamic v) => v == null ? null : DateTime.parse('$v').toLocal();

String time(DateTime t) => DateFormat('h:mm a').format(t).toLowerCase();

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// "today", "tomorrow", "yesterday", or null for any other day.
String? nearDay(DateTime t) {
  final now = DateTime.now();
  if (_sameDay(t, now)) return 'today';
  if (_sameDay(t, now.add(const Duration(days: 1)))) return 'tomorrow';
  if (_sameDay(t, now.subtract(const Duration(days: 1)))) return 'yesterday';
  return null;
}

/// "Tue 6 Oct": the day name, the date and the month, always.
String shortDate(DateTime t) => DateFormat('EEE d MMM').format(t);

/// "today", "tomorrow", "yesterday" or "Tue 6 Oct".
String day(DateTime t) => nearDay(t) ?? shortDate(t);

/// "today 9:00 pm", "Tue 6 Oct, 9:00 pm".
String when(DateTime t) {
  final d = day(t);
  return d.contains(' ') ? '$d, ${time(t)}' : '$d ${time(t)}';
}

// When a test opens or closes, the day is always spelled out: "tomorrow" alone leaves the reader to work out which day that is.

/// A day inside a sentence: "today, Thu 29 Oct" or "Sat 31 Oct".
String dayDate(DateTime t) {
  final near = nearDay(t);
  return near == null ? shortDate(t) : '$near, ${shortDate(t)}';
}

/// A start or end inside a sentence: "today, Thu 29 Oct, 6:00 pm" or "Sat 31 Oct, 6:00 pm".
String whenDate(DateTime t) => '${dayDate(t)}, ${time(t)}';

/// A day on its own, in a box or a list of days: "Today · Thu 29 Oct" or "Sat 31 Oct".
String dayTitle(DateTime t) {
  final near = nearDay(t);
  return near == null ? shortDate(t) : '${near[0].toUpperCase()}${near.substring(1)} · ${shortDate(t)}';
}

/// A start or end on its own, as a value: "Today · Thu 29 Oct, 6:00 pm" or "Sat 31 Oct, 6:00 pm".
String whenTitle(DateTime t) => '${dayTitle(t)}, ${time(t)}';

/// "45 s", "18 min", "1 h 5 min".
String duration(int seconds) {
  if (seconds < 60) return '$seconds s';
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  return '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60} min'}';
}

/// Countdown clock: "18:42" or "1:05:12".
String clock(Duration d) {
  if (d.isNegative) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// 14 -> "14", 13.5 -> "13.5".
String marks(num? v) {
  if (v == null) return '-';
  return v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);
}

/// "1 paper", "7 papers".
String count(num n, String one, [String? many]) => '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// How long is left until [t]: "3 h 10 min", "45 min", "2 days".
String left(DateTime t) {
  final d = t.difference(DateTime.now());
  if (d.inMinutes < 1) return 'under a minute';
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  if (d.inHours < 24) return '${d.inHours} h${d.inMinutes % 60 == 0 ? '' : ' ${d.inMinutes % 60} min'}';
  return '${d.inDays} day${d.inDays == 1 ? '' : 's'}';
}

String percent(num? fraction) => fraction == null ? '-' : '${(fraction * 100).round()}%';

String relative(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24 && _sameDay(t, DateTime.now())) return time(t);
  return day(t);
}
