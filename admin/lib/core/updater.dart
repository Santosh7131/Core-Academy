import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api.dart';
import 'device.dart';

/// One admin app release, as GET /admin/app describes it.
class Release {
  Release.fromJson(Map<String, dynamic> j)
      : version = '${j['version']}',
        build = (j['build'] as num).toInt(),
        apk = Uri.parse('${j['apk']}'),
        sha256 = '${j['sha256']}'.toLowerCase(),
        size = (j['size'] as num).toInt(),
        notes = '${j['notes'] ?? ''}'.trim();

  final String version;
  final int build;
  final Uri apk;
  final String sha256;
  final int size;
  final String notes;
}

enum UpdateStep { ready, allow, downloading, installing, failed }

/// The admin app updates itself like the main app, but from private storage: the API hands out
/// a short-lived download link to the developer login only (tools/release-admin.ps1 puts it there).
class Updater extends ChangeNotifier {
  static const _native = MethodChannel('core_academy/updater');

  Release? available;
  UpdateStep step = UpdateStep.ready;
  double progress = 0;
  String? problem;
  bool silent = true;
  String? _dir;
  bool _resumeAfterAllow = false;
  bool _started = false;

  Future<void> start() async {
    if (_started || !Platform.isAndroid) return;
    _started = true;
    _native.setMethodCallHandler(_fromAndroid);
    try {
      final info = await _native.invokeMapMethod<String, dynamic>('info');
      silent = info?['silent'] == true;
      _dir = info?['dir'] as String?;
    } on PlatformException {
      _started = false;
    }
  }

  /// Asks the API for a newer admin app. Returns whether one is out, or null when it could not ask.
  Future<bool?> check() async {
    if (!_started || api.token == null) return null;
    try {
      final r = await api.get('/admin/app');
      final u = r['update'];
      if (u is! Map) {
        available = null;
      } else {
        final rel = Release.fromJson(Map<String, dynamic>.from(u));
        available = rel.build > Device.build ? rel : null;
      }
      if (available != null && step == UpdateStep.failed) step = UpdateStep.ready;
      notifyListeners();
      return available != null;
    } catch (_) {
      return null;
    }
  }

  Future<void> resumed() async {
    if (!_started) return;
    if (_resumeAfterAllow) {
      _resumeAfterAllow = false;
      if (await _canInstall()) {
        unawaited(update());
      } else {
        step = UpdateStep.allow;
        notifyListeners();
      }
    }
  }

  Future<bool> _canInstall() async {
    try {
      return (await _native.invokeMapMethod<String, dynamic>('info'))?['canInstall'] == true;
    } on PlatformException {
      return false;
    }
  }

  Future<void> allow() async {
    _resumeAfterAllow = true;
    await _native.invokeMethod('allowInstalls');
  }

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
    final file = File('${dir.path}/admin-${r.build}.apk');
    await for (final f in dir.list()) {
      if (f.path != file.path) await f.delete(recursive: true);
    }
    if (await file.exists() && await file.length() == r.size) return file;
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
    switch (args['status']) {
      case 'confirm' || 'installed':
        step = UpdateStep.installing;
        notifyListeners();
      case 'cancelled':
        step = UpdateStep.ready;
        notifyListeners();
      case 'failed':
        final m = args['message'] as String?;
        _fail(m == null || m.isEmpty ? 'Android could not install the update.' : 'Android could not install the update: $m');
    }
  }
}

final updater = Updater();
