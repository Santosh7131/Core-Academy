import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const _liveApi = 'https://br-cold-shape-azcvozbw-api.compute.c-3.ap-southeast-1.aws.neon.tech';
const _devApi = 'https://br-nameless-shape-azg23hcy-api.compute.c-3.ap-southeast-1.aws.neon.tech';

/// The API base: release builds use the live (main branch) API, debug builds the dev branch.
/// Pass --dart-define=API_BASE=... to point a build anywhere else.
const apiBase = String.fromEnvironment('API_BASE', defaultValue: kReleaseMode ? _liveApi : _devApi);

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;

  bool get offline => status == 0;

  @override
  String toString() => message;
}

class Api {
  Api._();
  static final instance = Api._();

  final _client = http.Client();
  String? token;

  /// Called when the server says the session is gone (password reset, login turned off).
  void Function()? onSignedOut;

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Object? body, Duration? timeout]) => _send('POST', path, body: body, timeout: timeout);
  Future<dynamic> put(String path, [Object? body]) => _send('PUT', path, body: body);
  Future<dynamic> patch(String path, [Object? body]) => _send('PATCH', path, body: body);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, {Object? body, Duration? timeout}) async {
    final req = http.Request(method, Uri.parse('$apiBase$path'));
    if (token != null) req.headers['authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _client.send(req).timeout(timeout ?? const Duration(seconds: 25)));
    } on TimeoutException {
      throw ApiException(0, 'offline', 'The server is taking too long. Check your internet and try again.');
    } on SocketException {
      throw ApiException(0, 'offline', 'No internet connection. Check your connection and try again.');
    } on http.ClientException {
      throw ApiException(0, 'offline', 'No internet connection. Check your connection and try again.');
    }
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
      err is Map ? '${err['message']}' : 'Something went wrong. Please try again.',
    );
    if (e.status == 401 && e.code == 'signed_out' && token != null) onSignedOut?.call();
    throw e;
  }

  /// Uploads bytes straight to object storage with a presigned URL.
  Future<void> putBytes(String url, List<int> bytes, {String contentType = 'image/jpeg'}) async {
    try {
      final res = await _client
          .put(Uri.parse(url), headers: {'content-type': contentType}, body: bytes)
          .timeout(const Duration(seconds: 60));
      if (res.statusCode >= 300) throw ApiException(res.statusCode, 'upload_failed', 'The upload did not go through. Try again.');
    } on SocketException {
      throw ApiException(0, 'offline', 'No internet connection. Check your connection and try again.');
    } on TimeoutException {
      throw ApiException(0, 'offline', 'The upload is taking too long. Check your internet and try again.');
    }
  }
}

final api = Api.instance;
