import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'device.dart';

const _liveApi = 'https://br-cold-shape-azcvozbw-api.compute.c-3.ap-southeast-1.aws.neon.tech';
const _devApi = 'https://br-nameless-shape-azg23hcy-api.compute.c-3.ap-southeast-1.aws.neon.tech';

/// The API the app reads. A release build reads the live one, which the students use, and only
/// that. Test builds read dev, or another API with --dart-define=API_BASE=http://127.0.0.1:8787.
const apiBase = String.fromEnvironment('API_BASE', defaultValue: kReleaseMode ? _liveApi : _devApi);

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;

  @override
  String toString() => message;
}

class Api {
  Api._();
  static final instance = Api._();

  final _client = http.Client();
  String? token;

  /// How long the last request took, end to end, in milliseconds.
  int? lastMs;

  /// Called when the server says the session is gone.
  void Function()? onSignedOut;

  String get base => apiBase;

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body]) => _send('POST', path, body: body);

  Future<dynamic> _send(String method, String path, {Object? body}) async {
    final req = http.Request(method, Uri.parse('$base$path'));
    req.headers.addAll(Device.headers);
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final started = DateTime.now();
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 30)));
    } on TimeoutException {
      throw ApiException(0, 'offline', 'The server is taking too long. Check the internet and try again.');
    } on SocketException {
      throw ApiException(0, 'offline', 'No internet connection.');
    } on http.ClientException {
      throw ApiException(0, 'offline', 'No internet connection.');
    }
    lastMs = DateTime.now().difference(started).inMilliseconds;
    dynamic json;
    try {
      json = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      json = null;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    final err = json is Map ? json['error'] : null;
    final e = ApiException(
      res.statusCode,
      err is Map ? '${err['code']}' : 'server_error',
      err is Map ? '${err['message']}' : 'The server answered ${res.statusCode}.',
    );
    if (e.status == 401 && token != null) onSignedOut?.call();
    throw e;
  }
}

final api = Api.instance;
