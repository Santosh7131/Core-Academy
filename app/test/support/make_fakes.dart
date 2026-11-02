// The stand-in server and phone for the tests and pictures of making several tests at once: papers, pages, questions and tests kept
// the way the real server keeps them, a file picker that hands out PDFs made of a single byte (their page count), and a camera.
import 'dart:convert';
import 'dart:typed_data';

import 'package:core_academy/features/teacher/make_test.dart';
import 'package:core_academy/features/teacher/make_tests_screen.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class FakePaper {
  FakePaper(this.id, this.name, this.pages, this.plan, this.questions, this.unsure);
  final String id;
  String name;
  final int pages;
  final Map<String, dynamic>? plan;

  /// How many questions the paper has, and how many of them AI cannot settle.
  final int questions;
  final int unsure;
  final uploaded = <int>{};
  final read = <int>{};
  final drafts = <Map<String, dynamic>>[];
  final tests = <Map<String, dynamic>>[];
  bool detected = false;
}

class PaperServer {
  final papers = <String, FakePaper>{};
  final sent = <Map<String, dynamic>>[];
  final testBodies = <Map<String, dynamic>>[];
  final calls = <String>[];
  var _next = 1;

  /// How many questions a paper of a given name has (4 unless said) and how many of those AI cannot settle (none unless said).
  final questionsOf = <String, int>{};
  final unsureOf = <String, int>{};

  /// A paper that cannot be uploaded the first time its page is sent.
  final failUpload = <String>{};

  /// Holds a page back while it is being read: given the paper's name and the page, returns a future the reading waits for, or null to
  /// read it at once. For pictures of a paper half way through.
  Future<void>? Function(String name, int page)? hold;

  int count(String call) => calls.where((c) => c == call).length;

  /// A paper that has been read and answered already, as one left half way is: every page read, every question with its answer.
  FakePaper seed(String name, {int questions = 4, Map<String, dynamic>? plan, int pages = 1}) {
    final id = 'p${_next++}';
    final p = FakePaper(id, name, pages, plan, questions, 0)..detected = true;
    for (var n = 1; n <= pages; n++) {
      p.uploaded.add(n);
      p.read.add(n);
    }
    for (var k = 1; k <= questions; k++) {
      p.drafts.add({
        'id': '$id-d$k', 'paper_id': id, 'page_no': (k - 1) % pages + 1, 'seq': k, 'number_label': '$k', 'kind': 'mcq', 'status': 'draft',
        'text': 'Question $k of $name', 'options': ['2', '3', '4', '5'], 'correct_option': 1, 'answer_checked': true, 'needs_diagram': false,
        'image_key': null, 'image_url': null, 'ai_note': null, 'ai_votes': null, 'edited': false, 'question_id': null, 'answer_source': 'ai',
      });
    }
    papers[id] = p;
    return p;
  }

  /// Forgets every paper and test, as a new server would, and keeps what was set up for the run (question counts, holds).
  void reset() {
    papers.clear();
    sent.clear();
    testBodies.clear();
    calls.clear();
    failUpload.clear();
    _next = 1;
  }

  http.Response _ok(Object body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});
  http.Response _no(int status, String code, String message) => _ok({'error': {'code': code, 'message': message}}, status);

  Map<String, dynamic> _row(FakePaper p) => {
        'id': p.id, 'class_level': 10, 'exam_name': p.name, 'category': null, 'subject': 'Maths', 'subject_id': 'sub-Maths', 'chapter': null,
        'chapter_id': null, 'course_id': null, 'ai_details': p.detected ? {'ok': true} : null, 'page_count': p.pages, 'missing': <String>[],
        'replaceable': false, 'plan': p.plan,
      };

  Future<http.Response> handle(http.Request r) async {
    if (r.url.host == 'upload.test') {
      final key = r.url.path;
      if (failUpload.remove(key.split('/')[1])) return _no(500, 'upload_failed', 'The upload did not go through.');
      return http.Response('', 200);
    }
    final path = r.url.path;
    calls.add('${r.method} $path');
    final body = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;

    if (r.method == 'POST' && path == '/teacher/papers') {
      sent.add(body);
      final id = 'p${_next++}';
      final name = (body['exam_name'] as String?) ?? 'Paper 31 Oct';
      final p = FakePaper(id, name, body['pages'] as int, body['plan'] as Map<String, dynamic>?, questionsOf[name] ?? 4, unsureOf[name] ?? 0);
      papers[id] = p;
      return _ok({
        'paper': _row(p),
        'uploads': [for (var n = 1; n <= p.pages; n++) {'page_no': n, 'put_url': 'https://upload.test/$id/$n'}],
      }, 201);
    }

    final m = RegExp(r'^/teacher/papers/(p\d+)(/.*)?$').firstMatch(path);
    if (m != null) {
      final p = papers[m.group(1)!];
      if (p == null) return _no(404, 'not_found', 'This paper');
      final rest = m.group(2) ?? '';
      switch ('${r.method} $rest') {
        case 'GET ':
          final saved = p.drafts.where((d) => d['status'] == 'saved').toList();
          return _ok({
            'paper': _row(p),
            'pages': [for (var n = 1; n <= p.pages; n++) {'page_no': n, 'uploaded': p.uploaded.contains(n), 'ai_status': p.read.contains(n) ? 'done' : 'pending', 'image_url': null}],
            'drafts': p.drafts,
            'chapters': <Object?>[],
            'questions': [for (final d in saved) {'id': d['question_id'], 'text': d['text'], 'options': d['options'], 'correct_option': d['correct_option'], 'image_url': null}],
            'tests': p.tests,
          });
        case 'DELETE ':
          papers.remove(p.id);
          return _ok({});
        case 'POST /detect':
          p.detected = true;
          return _ok({});
        case 'POST /second-opinion':
          return _ok({'by_ai': 0, 'tried': 0, 'asked': 0, 'left': 0});
        case 'POST /save':
          var saved = 0;
          for (final d in p.drafts) {
            if (d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] != null) {
              d['status'] = 'saved';
              d['question_id'] = 'q-${d['id']}';
              saved++;
            }
          }
          final left = p.drafts.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq').length;
          return _ok({'saved': saved, 'already_in_bank': 0, 'still_to_check': left});
        case 'POST /answers':
          final todo = p.drafts.where((d) => d['status'] == 'draft' && d['answer_checked'] != true).toList();
          var settled = 0;
          for (final d in todo) {
            d['answer_checked'] = true;
            // The questions AI cannot settle stay without an answer, for the tutor.
            final number = int.parse('${d['number_label']}');
            if (number > p.questions - p.unsure) continue;
            d['correct_option'] = 1;
            d['answer_source'] = 'ai';
            settled++;
          }
          return _ok({'from_key': 0, 'by_ai': settled, 'tried': todo.length, 'left': 0, 'second': 0});
      }
      final page = RegExp(r'^POST /pages/(\d+)/(uploaded|read)$').firstMatch('${r.method} $rest');
      if (page != null) {
        final n = int.parse(page.group(1)!);
        if (page.group(2) == 'uploaded') {
          p.uploaded.add(n);
          return _ok({});
        }
        final held = hold?.call(p.name, n);
        if (held != null) await held;
        p.read.add(n);
        // Question k is on page ((k - 1) mod pages) + 1.
        for (var k = 1; k <= p.questions; k++) {
          if ((k - 1) % p.pages + 1 != n) continue;
          p.drafts.add({
            'id': '${p.id}-d$k', 'paper_id': p.id, 'page_no': n, 'seq': k, 'number_label': '$k', 'kind': 'mcq', 'status': 'draft',
            'text': 'Question $k of ${p.name}', 'options': ['2', '3', '4', '5'], 'correct_option': null, 'answer_checked': false, 'needs_diagram': false,
            'image_key': null, 'image_url': null, 'ai_note': null, 'ai_votes': null, 'edited': false, 'question_id': null,
          });
        }
        return _ok({'questions': p.drafts.length});
      }
    }

    if (r.method == 'POST' && path == '/teacher/tests') {
      testBodies.add(body);
      final id = 't${_next++}';
      final p = papers[body['paper_id']];
      p?.tests.add({'id': id, 'title': body['title'], 'status': 'draft', 'opens_at': body['opens_at'], 'closes_at': body['closes_at'], 'question_count': (body['question_ids'] as List).length});
      return _ok({'id': id}, 201);
    }
    final pub = RegExp(r'^/teacher/tests/(t\d+)/publish$').firstMatch(path);
    if (r.method == 'POST' && pub != null) {
      for (final p in papers.values) {
        for (final t in p.tests) {
          if (t['id'] == pub.group(1)) t['status'] = 'published';
        }
      }
      return _ok({});
    }
    return _no(404, 'not_found', 'No stub for ${r.method} $path');
  }

  /// The tutor went through a paper that needed her: every question has an answer now.
  void checked(String name) {
    for (final p in papers.values.where((p) => p.name == name)) {
      for (final d in p.drafts) {
        d['correct_option'] ??= 2;
      }
    }
  }
}

PickedPdf fakePdf(String file, int pages, {bool broken = false}) => PickedPdf(file, () async => broken ? Uint8List(0) : Uint8List.fromList([pages]));

class FakeSources extends PaperSources {
  FakeSources({this.pdfs = const [], this.photoSets = const []});
  List<PickedPdf> pdfs;
  final List<List<Uint8List>> photoSets;
  var _photoCalls = 0;

  @override
  Future<List<PickedPdf>> pickPdfs() async => pdfs;

  @override
  Future<int> pageCount(Uint8List pdf) async {
    if (pdf.isEmpty) throw StateError('not a PDF');
    return pdf.first;
  }

  @override
  Future<List<Uint8List>> render(Uint8List pdf, int limit, void Function(int page, int of) progress) async {
    final n = pdf.first < limit ? pdf.first : limit;
    return [
      for (var i = 1; i <= n; i++) () {
        progress(i, n);
        return Uint8List.fromList([i, i, i]);
      }(),
    ];
  }

  @override
  Future<List<Uint8List>?> photos(BuildContext context, TestTarget target) async => _photoCalls < photoSets.length ? photoSets[_photoCalls++] : null;
}
