// How the app's network calls behave when the connection misbehaves: a read that fails to connect is tried once more (a phone that has
// been idle often finds its old connection closed by the network, with the internet fine), a write is never sent twice, and an answer
// that stops half way is given up on, not waited for for ever.
//   flutter test test/api_retry_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_academy/core/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// What the stub network does with the next request; it counts them too.
Future<http.StreamedResponse> Function(http.BaseRequest) _next = (_) async => _ok();
var _requests = <String>[];

http.StreamedResponse _ok([Object body = const {'ok': true}]) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(body))), 200, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    http.runWithClient(() => api.token = 'test', () => MockClient.streaming((request, _) {
          _requests.add('${request.method} ${request.url.path}');
          return _next(request);
        }));
  });

  setUp(() {
    _requests = [];
    _next = (_) async => _ok();
  });

  test('a read that fails to connect once is tried again, and the screen never knows', () async {
    var tries = 0;
    _next = (_) async {
      if (++tries == 1) throw http.ClientException('Connection closed before full header was received');
      return _ok({'tests': []});
    };
    final r = await api.get('/student/home');
    expect(r, {'tests': []});
    expect(_requests, ['GET /student/home', 'GET /student/home']);
  });

  test('a read that fails twice says there is no internet', () async {
    _next = (_) async => throw const SocketException('no route to host');
    await expectLater(api.get('/student/home'), throwsA(isA<ApiException>().having((e) => e.offline, 'offline', true)));
    expect(_requests.length, 2, reason: 'one try and one more, not a loop');
  });

  test('a write that fails to connect is not sent again: it may have gone through', () async {
    _next = (_) async => throw http.ClientException('Connection reset by peer');
    await expectLater(api.post('/student/tests/t1/start'), throwsA(isA<ApiException>().having((e) => e.offline, 'offline', true)));
    await expectLater(api.put('/student/attempts/a1/answers', {'answers': []}), throwsA(isA<ApiException>()));
    expect(_requests, ['POST /student/tests/t1/start', 'PUT /student/attempts/a1/answers']);
  });

  test('an answer from the server is never read twice: an error is an answer', () async {
    _next = (_) async => http.StreamedResponse(
          Stream.value(utf8.encode(jsonEncode({'error': {'code': 'closed', 'message': 'This test has closed.'}}))),
          409,
          headers: {'content-type': 'application/json'},
        );
    await expectLater(api.get('/student/home'), throwsA(isA<ApiException>().having((e) => e.code, 'code', 'closed')));
    expect(_requests.length, 1);
  });

  testWidgets('an answer that stops half way is given up on', (t) async {
    final never = StreamController<List<int>>(); // the headers arrive, the body never does
    _next = (_) async => http.StreamedResponse(never.stream, 200, headers: {'content-type': 'application/json'});
    final call = api.get('/student/home');
    Object? failure;
    unawaited(call.then<void>((_) {}, onError: (Object e) => failure = e));
    await t.pump(const Duration(seconds: 20));
    expect(failure, isNull, reason: 'still within the time allowed');
    await t.pump(const Duration(seconds: 10));
    expect(failure, isA<ApiException>().having((e) => e.offline, 'offline', true));
    expect(failure.toString(), contains('taking too long'));
    await never.close();
  });
}
