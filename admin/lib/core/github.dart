import 'dart:convert';

import 'package:http/http.dart' as http;

/// The main app's releases on GitHub, read straight from the phone (the repository is public).
class AppRelease {
  AppRelease(this.version, this.published, this.downloads);
  final String version;
  final DateTime? published;

  /// Downloads of the release's APK, counted by GitHub.
  final int downloads;
}

const _repo = 'Santosh7131/Core-Academy';

List<AppRelease>? _cache;
DateTime? _cachedAt;

/// The newest releases, newest first. Null when GitHub could not be reached.
Future<List<AppRelease>?> appReleases() async {
  final at = _cachedAt;
  if (_cache != null && at != null && DateTime.now().difference(at) < const Duration(minutes: 10)) return _cache;
  try {
    final res = await http
        .get(Uri.parse('https://api.github.com/repos/$_repo/releases?per_page=6'), headers: {'accept': 'application/vnd.github+json'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) return _cache;
    _cachedAt = DateTime.now();
    return _cache = [
      for (final r in jsonDecode(res.body) as List)
        if (r['draft'] != true && r['prerelease'] != true)
          AppRelease(
            '${r['tag_name']}'.replaceFirst(RegExp('^v'), ''),
            DateTime.tryParse('${r['published_at']}')?.toLocal(),
            [for (final a in (r['assets'] as List? ?? const [])) if ('${a['name']}'.endsWith('.apk')) (a['download_count'] as num).toInt()]
                .fold(0, (x, y) => x + y),
          ),
    ];
  } catch (_) {
    return _cache;
  }
}

/// The newest release's version, such as "1.2.0", once GitHub has answered.
Future<String?> newestVersion() async {
  final r = await appReleases();
  return r == null || r.isEmpty ? null : r.first.version;
}
