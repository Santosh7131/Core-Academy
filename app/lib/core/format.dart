import 'package:intl/intl.dart';

DateTime? parseTime(dynamic v) => v == null ? null : DateTime.parse('$v').toLocal();

String time(DateTime t) => DateFormat('h:mm a').format(t).toLowerCase();

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// "today", "tomorrow", "yesterday" or "Tue 6 Oct".
String day(DateTime t) {
  final now = DateTime.now();
  if (_sameDay(t, now)) return 'today';
  if (_sameDay(t, now.add(const Duration(days: 1)))) return 'tomorrow';
  if (_sameDay(t, now.subtract(const Duration(days: 1)))) return 'yesterday';
  return DateFormat('EEE d MMM').format(t);
}

/// "today 9:00 pm", "Tue 6 Oct, 9:00 pm".
String when(DateTime t) {
  final d = day(t);
  return d.contains(' ') ? '$d, ${time(t)}' : '$d ${time(t)}';
}

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

String percent(num? fraction) => fraction == null ? '-' : '${(fraction * 100).round()}%';

String relative(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24 && _sameDay(t, DateTime.now())) return time(t);
  return day(t);
}
