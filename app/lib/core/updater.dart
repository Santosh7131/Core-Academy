import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Where the app looks for a newer version of itself: a small JSON file attached to every
/// GitHub release (tools/release-app.ps1 writes it), reached through GitHub's link to the
/// latest release. Debug builds have no feed unless --dart-define=UPDATE_FEED=... gives one,
/// so a test build never offers to replace itself with the live app.
const updateFeed = String.fromEnvironment(
  'UPDATE_FEED',
  defaultValue: kReleaseMode ? 'https://github.com/Santosh7131/Core-Academy/releases/latest/download/update.json' : '',
);

/// One release, as the feed describes it.
class Release {
  Release.fromJson(Map<String, dynamic> j)
      : version = '${j['version']}',
        build = (j['build'] as num).toInt(),
        apk = Uri.parse('${j['apk']}'),
        sha256 = '${j['sha256']}'.toLowerCase(),
        size = (j['size'] as num).toInt(),
        notes = '${j['notes'] ?? ''}'.trim();

  final String version;

  /// The number after the + in pubspec.yaml. A release is newer when this is higher.
  final int build;
  final Uri apk;
  final String sha256;
  final int size;
  final String notes;
}

enum UpdateStep {
  /// A newer version is out and nothing has started.
  ready,

  /// Waiting for the user to let Core Academy install apps (once per phone).
  allow,
  downloading,

  /// Android has the new version; it closes the app while it puts it in.
  installing,
  failed,
}

/// Finds a newer version of the app, downloads it and hands it to Android to install
/// (android/.../Updater.kt). Home listens to it for the "update ready" card.
class Updater extends ChangeNotifier {
  static const _native = MethodChannel('core_academy/updater');

  /// The version on this phone, such as "1.2.0".
  String? version;
  int _build = 0;
  String? _dir;
  bool _started = false;
  DateTime? _checkedAt;

  /// A newer release, once one is found.
  Release? available;
  UpdateStep step = UpdateStep.ready;

  /// Download progress from 0 to 1.
  double progress = 0;
  String? problem;

  /// Android 12 and later put the update in without asking; older Android shows its Install prompt.
  bool silent = true;

  /// The user went to Android's settings to allow installs; carry on when the app comes back.
  bool _resumeAfterAllow = false;

  /// Whether this build looks for updates at all (release builds, or a test build given a feed).
  bool get enabled => updateFeed.isNotEmpty && Platform.isAndroid;

  Future<void> start() async {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _native.setMethodCallHandler(_fromAndroid);
    try {
      final info = await _native.invokeMapMethod<String, dynamic>('info');
      version = info?['version'] as String?;
      _build = (info?['build'] as num?)?.toInt() ?? 0;
      silent = info?['silent'] == true;
      _dir = info?['dir'] as String?;
    } on PlatformException {
      return;
    }
    notifyListeners();
    await check();
  }

  /// Looks for a newer release, at most every two hours unless [force]. Returns whether a newer
  /// version is out, or null when the feed could not be reached (offline): then it keeps what it knew.
  Future<bool?> check({bool force = false}) async {
    if (!enabled || _build == 0) return false;
    final last = _checkedAt;
    if (!force && last != null && DateTime.now().difference(last) < const Duration(hours: 2)) return available != null;
    try {
      final res = await http.get(Uri.parse(updateFeed)).timeout(const Duration(seconds: 20));
      // GitHub answers 404 while the latest release has no feed file: nothing newer to offer.
      if (res.statusCode == 404) return available != null;
      if (res.statusCode != 200) return null;
      final r = Release.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
      _checkedAt = DateTime.now();
      if (r.build > _build) {
        if (available?.build != r.build) {
          available = r;
          step = UpdateStep.ready;
          problem = null;
          notifyListeners();
        }
      } else if (available != null) {
        available = null;
        notifyListeners();
      }
    } catch (_) {
      // Offline, or a feed this version cannot read: try again next time.
      return null;
    }
    return available != null;
  }

  /// The app came back to the front.
  Future<void> resumed() async {
    if (!enabled || !_started) return;
    if (_resumeAfterAllow) {
      _resumeAfterAllow = false;
      if (await _canInstall()) {
        unawaited(update());
      } else {
        step = UpdateStep.allow;
        notifyListeners();
      }
      return;
    }
    await check();
  }

  Future<bool> _canInstall() async {
    try {
      final info = await _native.invokeMapMethod<String, dynamic>('info');
      return info?['canInstall'] == true;
    } on PlatformException {
      return false;
    }
  }

  /// Opens Android's "Install unknown apps" switch for Core Academy.
  Future<void> allow() async {
    _resumeAfterAllow = true;
    await _native.invokeMethod('allowInstalls');
  }

  /// Downloads the newer version and installs it. Android closes the app while it does.
  Future<void> update() async {
    final r = available;
    if (r == null || step == UpdateStep.downloading || step == UpdateStep.installing) return;
    problem = null;
    if (!await _canInstall()) {
      step = UpdateStep.allow;
      notifyListeners();
      return;
    }
    step = UpdateStep.downloading;
    progress = 0;
    notifyListeners();
    try {
      final file = await _download(r);
      step = UpdateStep.installing;
      notifyListeners();
      await _native.invokeMethod('install', {'path': file.path, 'sha256': r.sha256, 'version': r.version});
    } on PlatformException catch (e) {
      _fail(e.message ?? 'The update could not be installed.');
    } catch (_) {
      _fail('The download stopped. Check the internet and try again.');
    }
  }

  Future<File> _download(Release r) async {
    final dir = Directory(_dir!);
    await dir.create(recursive: true);
    final file = File('${dir.path}/core-academy-${r.build}.apk');
    // Only this download is worth keeping; older ones are spent.
    await for (final f in dir.list()) {
      if (f.path != file.path) await f.delete(recursive: true);
    }
    if (await file.exists() && await file.length() == r.size) {
      progress = 1;
      return file;
    }
    final part = File('${file.path}.part');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', r.apk)).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: r.apk);
      final sink = part.openWrite();
      var got = 0;
      var shown = 0.0;
      try {
        await for (final chunk in res.stream.timeout(const Duration(seconds: 45))) {
          sink.add(chunk);
          got += chunk.length;
          final p = got / r.size;
          if (p - shown >= 0.01) {
            shown = p;
            progress = p.clamp(0, 1).toDouble();
            notifyListeners();
          }
        }
      } finally {
        await sink.close();
      }
      if (got != r.size) throw HttpException('Got $got of ${r.size} bytes', uri: r.apk);
      return await part.rename(file.path);
    } finally {
      client.close();
    }
  }

  void _fail(String message) {
    step = UpdateStep.failed;
    problem = message;
    notifyListeners();
  }

  Future<void> _fromAndroid(MethodCall call) async {
    if (call.method != 'status') return;
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final message = args['message'] as String?;
    switch (args['status']) {
      case 'confirm' || 'installed':
        step = UpdateStep.installing;
        notifyListeners();
      case 'cancelled':
        step = UpdateStep.ready;
        notifyListeners();
      case 'failed':
        _fail(message == null || message.isEmpty ? 'Android could not install the update.' : 'Android could not install the update: $message');
    }
  }
}

final updater = Updater();
