import 'package:intl/intl.dart';

DateTime? parseTime(Object? v) => v == null ? null : DateTime.tryParse('$v')?.toLocal();

/// "7:58 am", with a no-break space so "am" never wraps onto a line of its own.
String time(DateTime t) => '${DateFormat('h:mm').format(t)} ${t.hour < 12 ? 'am' : 'pm'}';

/// "now", "4 min ago", "2 h ago", "today 7:58 am", "yesterday 8:14 pm", "Sat 6:40 pm", "26 Sep".
String ago(DateTime? t, {DateTime? now}) {
  if (t == null) return 'never';
  final n = now ?? DateTime.now();
  final d = n.difference(t);
  if (d.inSeconds < 90) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 4) return '${d.inHours} h ago';
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(t.year, t.month, t.day);
  if (day == today) return 'today ${time(t)}';
  if (day == DateTime(n.year, n.month, n.day - 1)) return 'yesterday ${time(t)}';
  if (d.inDays < 7) return '${DateFormat('EEE').format(t)} ${time(t)}';
  return DateFormat(t.year == n.year ? 'd MMM' : 'd MMM y').format(t);
}

/// "3 Oct, 6:12 pm"
String when(DateTime? t) => t == null ? '-' : '${DateFormat('d MMM').format(t)}, ${time(t)}';

/// "7:58 am", or "3 Oct" when not today.
String clock(DateTime? t) {
  if (t == null) return '-';
  final n = DateTime.now();
  if (t.year == n.year && t.month == n.month && t.day == n.day) return time(t);
  return DateFormat('d MMM').format(t);
}

/// "Today", "Yesterday", "Sat 3 October", or "3 October 2025" in another year.
String dayLabel(DateTime t) {
  final n = DateTime.now();
  final d = DateTime(t.year, t.month, t.day);
  if (d == DateTime(n.year, n.month, n.day)) return 'Today';
  if (d == DateTime(n.year, n.month, n.day - 1)) return 'Yesterday';
  return DateFormat(t.year == n.year ? 'EEE d MMMM' : 'd MMMM y').format(t);
}

String bytes(num b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).round()} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(b < 10 * 1024 * 1024 ? 1 : 0)} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

final _indian = NumberFormat.decimalPattern('en_IN');

/// 1,204 and 1,00,000: Indian grouping.
String count(num n) => _indian.format(n);

String plural(num n, String one, [String? many]) => '${count(n)} ${n == 1 ? one : (many ?? '${one}s')}';

int asInt(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
double asDouble(Object? v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

final _rupees2 = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
final _rupees0 = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

/// ₹12.40, and ₹1,234 from a thousand up, where paise are noise.
String rupees(num n) => n >= 1000 ? _rupees0.format(n) : _rupees2.format(n);

/// 840, 12.4k, 1.2M: a token count at a glance.
String tokens(num n) {
  if (n < 1000) return '${n.round()}';
  if (n < 1000000) return '${(n / 1000).toStringAsFixed(n < 10000 ? 1 : 0)}k';
  return '${(n / 1000000).toStringAsFixed(1)}M';
}
