// The stand-in server and phone for the tests and pictures of the Library: a shelf kept the way the real server keeps it (sections, files,
// uploads that are started and completed), a network that takes the bytes of an upload, a file picker, and a phone that opens and saves files.
import 'dart:convert';
import 'dart:io';

import 'package:core_academy/core/api.dart';
import 'package:core_academy/core/library.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

const mb = 1024 * 1024;

/// One shelf, the pages of a group and a course that carry its file count, and what a student is shown, all as the real server answers.
class LibraryServer {
  final sections = <Map<String, dynamic>>[];

  /// Every call, as "POST /teacher/library/sections/s1/files" (with "?query" when it had one), and the bodies of the calls that wrote.
  final calls = <String>[];
  final bodies = <Map<String, dynamic>>[];
  final _pending = <String, Map<String, dynamic>>{};

  /// The parts storage has, by file: filled in by the network stand-in as the parts arrive.
  final _sentParts = <String, Set<int>>{};
  var _sectionIds = 1;
  var _fileIds = 1;

  /// How many students the group page lists, and how many people the course page lists; and the tests both of them list (none by default).
  int people = 3;
  List<Object?> tests = [];

  /// The next this many completes answer that a part is missing (part 2 is forgotten), as the server does when a part did not arrive.
  int incompleteCompletes = 0;

  /// When set, starting a file is refused with this code and message (the Library is full, say).
  ({int status, String code, String message})? refuseStart;

  /// What the student's screens are given: the home counts, the courses, the shelves; and a switch to make the shelves fail to load.
  Map<String, dynamic> home = {};
  List<Object?> courseList = [];
  Map<String, dynamic> student = {'groups': <Object?>[], 'courses': <Object?>[]};
  bool studentDown = false;

  /// How many times [call] was made ("DELETE /teacher/library/sections/s2"), with or without a query.
  int count(String call) => calls.where((c) => c == call || c.startsWith('$call?')).length;

  /// The finished files on the shelf.
  int get files => sections.fold(0, (n, s) => n + (s['files'] as List).length);

  /// A file as the server describes it, in the type its name says.
  static Map<String, dynamic> fileJson(String id, String section, String name, int size, {String? type}) {
    final t = type ?? contentTypeOf(name) ?? 'application/pdf';
    return {
      'id': id,
      'section_id': section,
      'name': name,
      'kind': t == 'application/pdf' ? 'pdf' : 'photo',
      'content_type': t,
      'size_bytes': size,
      'created_at': '2026-10-29T10:00:00Z',
    };
  }

  /// A section with files already on it. Each file is a (name, size) pair.
  Map<String, dynamic> seed(String name, [List<(String, int)> files = const []]) {
    final id = 's${_sectionIds++}';
    final s = <String, dynamic>{'id': id, 'name': name, 'position': sections.length, 'files': <Map<String, dynamic>>[]};
    sections.add(s);
    for (final (n, size) in files) {
      (s['files'] as List).add(fileJson('f${_fileIds++}', id, n, size));
    }
    return s;
  }

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});
  http.Response _no(int status, String code, String message) => _ok({'error': {'code': code, 'message': message}}, status);

  Map<String, dynamic>? _sec(String id) => sections.where((s) => s['id'] == id).firstOrNull;

  List<Object?> _people(String prefix) => [
        for (var i = 0; i < people; i++) {'id': '$prefix$i', 'display_name': 'Person $i', 'active': true, 'tests_done': 0, 'avg_pct': null},
      ];

  Future<http.Response> handle(http.Request r) async {
    final path = r.url.path;
    calls.add('${r.method} $path${r.url.hasQuery ? '?${r.url.query}' : ''}');
    final body = r.body.isEmpty ? <String, dynamic>{} : Map<String, dynamic>.from(jsonDecode(r.body) as Map);
    if (r.method != 'GET') bodies.add(body);
    RegExpMatch? m(String pattern) => RegExp('^$pattern\$').firstMatch(path);

    // ---- the pages the Library tab sits on
    if (path == '/teacher/groups/10/sub-maths') return _ok({'tests': tests, 'students': _people('s'), 'library': files});
    if (path == '/teacher/courses/c-1') {
      return _ok({
        'course': {'id': 'c-1', 'name': 'Spoken English, Batch 1', 'people': people},
        'tests': tests,
        'people': _people('p'),
        'library': files,
      });
    }

    // ---- the tutor's shelf
    if (m(r'/teacher/(?:groups/10/sub-maths|courses/c-1)/library') != null && r.method == 'GET') {
      return _ok({'library': {'sections': sections, 'files': files, 'bytes': 0, 'used_bytes': 0, 'quota_bytes': 2048 * mb, 'max_file_bytes': 100 * mb}});
    }
    if (m(r'/teacher/(?:groups/10/sub-maths|courses/c-1)/library/sections') != null && r.method == 'POST') {
      final name = '${body['name']}';
      if (sections.any((s) => '${s['name']}'.toLowerCase() == name.toLowerCase())) return _no(409, 'duplicate', 'There is already a section called $name.');
      return _ok({'section': seed(name)}, 201);
    }
    final sec = m(r'/teacher/library/sections/([^/]+)');
    if (sec != null) {
      final s = _sec(sec.group(1)!);
      if (s == null) return _no(404, 'not_found', 'This section was not found.');
      if (r.method == 'PATCH') {
        final name = '${body['name']}';
        if (sections.any((x) => x != s && '${x['name']}'.toLowerCase() == name.toLowerCase())) return _no(409, 'duplicate', 'There is already a section called $name.');
        s['name'] = name;
        return _ok({'section': s});
      }
      if (r.method == 'DELETE') {
        final n = (s['files'] as List).length;
        if (n > 0 && r.url.queryParameters['with_files'] != '1') return _no(409, 'has_files', 'This section has $n files. Deleting it deletes them too.');
        sections.remove(s);
        return _ok({'ok': true, 'files_deleted': n});
      }
    }
    final start = m(r'/teacher/library/sections/([^/]+)/files');
    if (start != null && r.method == 'POST') {
      final refuse = refuseStart;
      if (refuse != null) return _no(refuse.status, refuse.code, refuse.message);
      final size = (body['size'] as num).toInt();
      final type = '${body['content_type']}';
      final f = fileJson('f${_fileIds++}', start.group(1)!, '${body['name']}', size, type: type);
      _pending[f['id'] as String] = f;
      return _ok({'file': {...f, 'status': 'uploading'}, 'upload': _plan(f['id'] as String, size, type)}, 201);
    }
    final again = m(r'/teacher/library/files/([^/]+)/upload');
    if (again != null && r.method == 'POST') {
      final f = _pending[again.group(1)!];
      if (f == null) return _no(404, 'not_found', 'This file was not found.');
      return _ok({'file': {...f, 'status': 'uploading'}, 'upload': _plan(again.group(1)!, (f['size_bytes'] as num).toInt(), '${f['content_type']}')});
    }
    final done = m(r'/teacher/library/files/([^/]+)/complete');
    if (done != null && r.method == 'POST') {
      final id = done.group(1)!;
      if (incompleteCompletes > 0) {
        incompleteCompletes--;
        _sentParts[id]?.remove(2);
        return _no(409, 'incomplete', 'The file did not finish going up. Try again.');
      }
      final f = _pending.remove(id);
      if (f == null) return _no(404, 'not_found', 'This file was not found.');
      (_sec(f['section_id'] as String)!['files'] as List).add(f);
      return _ok({'file': f});
    }
    final file = m(r'/teacher/library/files/([^/]+)');
    if (file != null) {
      final id = file.group(1)!;
      if (r.method == 'DELETE') {
        _pending.remove(id);
        for (final s in sections) {
          (s['files'] as List).removeWhere((x) => x['id'] == id);
        }
        return _ok({'ok': true});
      }
      if (r.method == 'PATCH') {
        for (final s in sections) {
          final list = s['files'] as List;
          final f = list.cast<Map<String, dynamic>>().where((x) => x['id'] == id).firstOrNull;
          if (f == null) continue;
          if (body['name'] != null) f['name'] = body['name'];
          if (body['section_id'] != null) {
            list.remove(f);
            f['section_id'] = body['section_id'];
            (_sec('${body['section_id']}')!['files'] as List).add(f);
          }
          return _ok({'file': f});
        }
        return _no(404, 'not_found', 'This file was not found.');
      }
    }

    // ---- the student's side
    if (path == '/student/home') return _ok(home);
    if (path == '/student/courses') return _ok({'courses': courseList});
    if (path == '/student/library') return studentDown ? _no(500, 'server_error', 'Something went wrong. Please try again.') : _ok(student);
    return _no(404, 'not_found', 'No stub for $path');
  }

  /// What the server answers to "send this file": one link for a small file, a link for each part of a big one (and none for a part it has).
  Map<String, dynamic> _plan(String id, int size, String type) {
    if (size <= 8 * mb) {
      return {'mode': 'single', 'url': 'https://storage.test/$id', 'headers': {'content-type': type}};
    }
    final n = (size / (8 * mb)).ceil();
    final have = _sentParts[id] ?? <int>{};
    return {
      'mode': 'multipart',
      'part_size': 8 * mb,
      'parts': [
        for (var i = 1; i <= n; i++)
          {'n': i, 'size': i < n ? 8 * mb : size - 8 * mb * (n - 1), 'done': have.contains(i), if (!have.contains(i)) 'url': 'https://storage.test/$id/$i'},
      ],
    };
  }
}

/// The network a file goes up over: takes the bytes and says what storage answers; can drop the connection first, or hold a send back.
class FakeNet {
  FakeNet(this.server);
  final LibraryServer server;

  /// Every send that reached storage whole: where it went and how many bytes it carried.
  final puts = <({String url, int length})>[];

  /// The next this many sends lose the connection half way.
  int dropNext = 0;

  /// What storage answers (200 unless a test says otherwise).
  int status = 200;

  /// Holds each send back, half way through, until this completes, so a test can look at a file that is on its way.
  Future<void>? hold;

  Putter get put => (job, url, length, body, headers, sent) async {
        final half = length ~/ 2;
        if (dropNext > 0) {
          dropNext--;
          sent(half);
          throw const SocketException('connection lost');
        }
        sent(half);
        var got = 0;
        await for (final chunk in body) {
          got += chunk.length;
        }
        await hold;
        sent(length - half);
        puts.add((url: url, length: got));
        final m = RegExp(r'https://storage\.test/([^/]+)/(\d+)$').firstMatch(url);
        if (m != null && status >= 200 && status < 300) (server._sentParts[m.group(1)!] ??= {}).add(int.parse(m.group(2)!));
        return status;
      };
}

/// The phone's file picker, gallery and camera: hands out what the test gave it, or fails as a phone does without permission.
class FakeSources extends LibrarySources {
  FakeSources({this.pdfs = const [], this.photos = const [], this.camera, this.fail});
  List<PickedFile> pdfs;
  List<PickedFile> photos;
  PickedFile? camera;
  PlatformException? fail;

  /// What was asked for, in order: 'pdf', 'gallery', 'camera'.
  final asked = <String>[];

  @override
  Future<List<PickedFile>> pickPdfs() async {
    asked.add('pdf');
    if (fail != null) throw fail!;
    return pdfs;
  }

  @override
  Future<List<PickedFile>> pickPhotos() async {
    asked.add('gallery');
    if (fail != null) throw fail!;
    return photos;
  }

  @override
  Future<PickedFile?> takePhoto() async {
    asked.add('camera');
    if (fail != null) throw fail!;
    return camera;
  }
}

/// The phone opening and saving files: nothing is downloaded, and each call is written down.
class FakeStore extends FileStore {
  /// Files fetched ("student:f1" or "teacher:f1") and names saved.
  final fetched = <String>[];
  final saved = <String>[];

  /// When set, fetching fails with this message, as it does without a connection.
  String? failWith;

  /// Where saved files are said to go; null stands for a phone that opens its share sheet instead.
  String? savedTo = 'Downloads';

  late final File photo = (() {
    final f = File('${Directory.systemTemp.path}/library-test-photo.png');
    // A 1 x 1 picture, so showing a photo has something real to draw.
    f.writeAsBytesSync(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='));
    return f;
  })();

  @override
  Future<File> fetch(LibFile file, {required bool teacher, void Function(double fraction)? progress}) async {
    // Like the real thing, this takes a moment before it says anything.
    await Future<void>.value();
    if (failWith != null) throw ApiException(0, 'offline', failWith!);
    fetched.add('${teacher ? 'teacher' : 'student'}:${file.id}');
    progress?.call(0.5);
    progress?.call(1);
    return file.isPdf ? File('${Directory.systemTemp.path}/library-test-${file.id}.pdf') : photo;
  }

  @override
  Future<String?> save(File file, LibFile info) async {
    saved.add(info.saveName);
    return savedTo;
  }
}

/// Stands in for the PDF pages pdfx draws: says it is a PDF, and that it has 12 pages.
Widget fakePdfPages(File file, void Function(int page, int pages) onPage) => Builder(builder: (context) {
      onPage(1, 12);
      return const Center(child: Text('The pages of the PDF'));
    });
