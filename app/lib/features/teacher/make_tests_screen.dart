import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/pool.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/tokens.dart';
import 'common.dart';
import 'make_test.dart';
import 'paper_runner.dart';
import 'papers_screens.dart' show AiProgressCard, UploadPaperScreen;
import 'pdf_pages.dart';

/// Making tests from papers: one to ten papers at once, each becoming its own test on its own day. The tutor picks the class, adds
/// the papers, chooses the days, AI reads every paper, and the tests that are ready are posted. Everything else (a paper that needs
/// checking) waits on Home until the tutor has been through it.

/// Ten papers at a time is the most: AI reads one paper after another, and a long queue is better made in two goes.
const _maxPapers = 10;

// ---------------------------------------------------------------- where papers come from

/// A PDF the tutor picked: its file name and a way to read it.
class PickedPdf {
  const PickedPdf(this.name, this.read);
  final String name;
  final Future<Uint8List> Function() read;
}

/// The phone's files and camera. Tests put their own in.
class PaperSources {
  const PaperSources();

  /// Opens the file picker for PDFs, several at once.
  Future<List<PickedPdf>> pickPdfs() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    return [for (final x in files) PickedPdf(x.name, x.readAsBytes)];
  }

  /// How many pages a PDF has. Throws when it cannot be opened.
  Future<int> pageCount(Uint8List pdf) => pdfPageCount(pdf);

  /// A PDF's first [limit] pages as JPEGs, [progress] hearing of each page as it starts.
  Future<List<Uint8List>> render(Uint8List pdf, int limit, void Function(int page, int of) progress) =>
      renderPdfPages(pdf, limit: limit, progress: progress);

  /// The pages of one paper photographed or chosen from the gallery; null when the tutor came back without any.
  Future<List<Uint8List>?> photos(BuildContext context, TestTarget target) => Navigator.of(context).push<List<Uint8List>>(MaterialPageRoute(
        builder: (_) => UploadPaperScreen(
          collect: true,
          classLevel: target.classLevel,
          subjectId: target.subjectId,
          subjectName: target.plainName,
          courseId: target.courseId,
        ),
      ));
}

// ---------------------------------------------------------------- times

/// How a test runs: when it opens and closes on its day (minutes after midnight), how long it takes and whether its questions are
/// shuffled. No limit means a minute and a half a question, worked out once the paper has been read.
class _Times {
  const _Times({this.opens = 8 * 60, this.closes = 21 * 60, this.limit, this.shuffle = true});
  final int opens;
  final int closes;
  final int? limit;
  final bool shuffle;

  _Times copyWith({int? opens, int? closes, bool? shuffle}) => _Times(opens: opens ?? this.opens, closes: closes ?? this.closes, limit: limit, shuffle: shuffle ?? this.shuffle);
  _Times withLimit(int? limit) => _Times(opens: opens, closes: closes, limit: limit, shuffle: shuffle);

  @override
  bool operator ==(Object other) => other is _Times && other.opens == opens && other.closes == closes && other.limit == limit && other.shuffle == shuffle;

  @override
  int get hashCode => Object.hash(opens, closes, limit, shuffle);
}

DateTime _at(DateTime day, int minutes) => DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);

String _clock(int minutes) => f.time(DateTime(2000, 1, 1, minutes ~/ 60, minutes % 60));

String _range(_Times t) => '${_clock(t.opens)} to ${_clock(t.closes)}';

String _limitWords(int? limit) => limit == null ? '1½ minutes a question' : '$limit min';

/// A test planned for a paper, with its days worked out: what goes to the server with the paper.
class _Planned {
  const _Planned({this.opens, required this.closes, this.limit, required this.shuffle});

  /// Null when the test is already open (its opening time has passed).
  final DateTime? opens;
  final DateTime closes;
  final int? limit;
  final bool shuffle;

  Map<String, dynamic> toJson() => {
        if (opens != null) 'opens_at': opens!.toUtc().toIso8601String(),
        'closes_at': closes.toUtc().toIso8601String(),
        if (limit != null) 'time_limit_min': limit,
        'shuffle': shuffle,
      };
}

/// "Real_Numbers test.pdf" becomes "Real Numbers test": a test's name, from its paper's file name.
String testNameFromFile(String file) {
  final bare = file.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '').replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final name = bare.isEmpty ? 'Paper' : bare;
  return name.length > 80 ? name.substring(0, 80).trim() : name;
}

// ---------------------------------------------------------------- one paper

enum _Stage { waiting, preparing, uploading, reading, read, failed }

/// What a paper is to the tutor at this moment.
enum _Status { working, failed, empty, check, ready, posted }

class _Item {
  _Item(this.key, {required this.name, required this.named, required this.pages, this.pdf, this.photos, this.note});
  final int key;

  /// What the tutor sees; for a paper from photos before AI has named it, a placeholder.
  String name;

  /// The tutor (or the file's name) gave the paper its name, so AI leaves it alone.
  bool named;
  final int pages;
  final PickedPdf? pdf;
  final List<Uint8List>? photos;

  /// "first 20 of 34 pages": said under a PDF that is longer than a paper can be.
  final String? note;

  /// Its own day; null follows the first test's day, one day after the paper before.
  DateTime? day;

  /// Its own times and order; null follows the ones every test shares.
  _Times? own;

  _Planned? planned;
  String? id;
  bool sent = false;
  _Stage stage = _Stage.waiting;
  String? status;
  String? error;
  PaperRunner? runner;

  bool posted = false;

  /// What the posted test turned out to be, for the list at the end.
  int? questions;
  int? limit;
}

enum _Step { which, papers, days, work }

enum _Phase { reading, check, ready, done }

class MakeTestsScreen extends StatefulWidget {
  /// [target] is the class when it is known (from a group's or a course's page); with [targets] instead the tutor chooses first.
  const MakeTestsScreen({super.key, this.target, this.targets = const [], this.sources = const PaperSources()});
  final TestTarget? target;
  final List<TestTarget> targets;
  final PaperSources sources;

  @override
  State<MakeTestsScreen> createState() => _MakeTestsScreenState();
}

class _MakeTestsScreenState extends State<MakeTestsScreen> {
  TestTarget? _target;
  List<TestTarget> _targets = const [];
  TestTarget? _picked;
  String? _loadError;

  /// The class was asked for, so Back from the next step goes there.
  bool _asked = false;
  _Step _step = _Step.which;

  final List<_Item> _items = [];
  int _keys = 0;
  late DateTime _first;
  _Times _shared = const _Times();

  bool _adding = false;
  bool _running = false;
  bool _stop = false;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _first = DateTime(now.year, now.month, now.day + 1);
    _targets = widget.targets;
    _target = widget.target ?? (_targets.length == 1 ? _targets.first : null);
    _picked = _targets.isEmpty ? null : _targets.first;
    _asked = _target == null;
    _step = _target == null ? _Step.which : _Step.papers;
    if (_target == null && _targets.isEmpty) _loadTargets();
  }

  @override
  void dispose() {
    _stopAll();
    super.dispose();
  }

  void _stopAll() {
    _stop = true;
    for (final it in _items) {
      it.runner?.stop();
    }
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  /// The classes to choose from, when the screen was opened without them.
  Future<void> _loadTargets() async {
    setState(() => _loadError = null);
    try {
      final d = await api.get('/teacher/home');
      List<Map<String, dynamic>> list(String key) => ((d[key] as List?) ?? const []).cast<Map<String, dynamic>>();
      final all = [
        for (final g in list('groups')) TestTarget.fromGroup(g),
        for (final c in list('courses')) TestTarget.fromCourse(c),
      ];
      if (!mounted) return;
      setState(() {
        _targets = all;
        _picked = all.isEmpty ? null : all.first;
        if (all.length == 1) {
          _target = all.first;
          _asked = false;
          _step = _Step.papers;
        }
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _loadError = e.message);
    }
  }

  // ---------------------------------------------------------------- the days

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  DateTime _dayOf(int i) => _items[i].day ?? DateTime(_first.year, _first.month, _first.day + i);

  _Times _timesOf(int i) => _items[i].own ?? _shared;

  _Planned _plan(int i) {
    final t = _timesOf(i);
    final day = _dayOf(i);
    final opens = _at(day, t.opens);
    return _Planned(opens: opens.isAfter(DateTime.now()) ? opens : null, closes: _at(day, t.closes), limit: t.limit, shuffle: t.shuffle);
  }

  /// Why test [i] cannot be made as planned, in words for the tutor; null when it can.
  String? _problem(int i) {
    final t = _timesOf(i);
    if (t.closes <= t.opens) return 'closes before it opens';
    if (_at(_dayOf(i), t.closes).isBefore(DateTime.now().add(const Duration(minutes: 5)))) return 'closes in the past';
    return null;
  }

  // ---------------------------------------------------------------- adding papers

  Future<void> _addPdfs() async {
    final List<PickedPdf> picked;
    try {
      picked = await widget.sources.pickPdfs();
    } catch (_) {
      return;
    }
    if (picked.isEmpty || !mounted) return;
    setState(() => _adding = true);
    final unreadable = <String>[];
    var skipped = 0;
    for (final p in picked) {
      if (_items.length >= _maxPapers) {
        skipped++;
        continue;
      }
      try {
        final pages = await widget.sources.pageCount(await p.read());
        if (pages < 1) throw StateError('no pages');
        _items.add(_Item(
          _keys++,
          name: testNameFromFile(p.name),
          named: true,
          pages: math.min(pages, maxPaperPages),
          pdf: p,
          note: pages > maxPaperPages ? 'first $maxPaperPages of $pages pages' : null,
        ));
      } catch (_) {
        unreadable.add(p.name);
      }
    }
    if (!mounted) return;
    setState(() => _adding = false);
    final said = [
      if (unreadable.isNotEmpty) '${unreadable.length == 1 ? '"${unreadable.first}"' : '${unreadable.length} of the PDFs'} could not be opened. Try photographing the pages instead.',
      if (skipped > 0) 'Ten papers at a time is the most, so ${f.count(skipped, 'PDF')} ${skipped == 1 ? 'was' : 'were'} left out. Make those in a second go.',
    ];
    if (said.isNotEmpty) await showProblem(context, ApiException(0, 'pdf', said.join('\n')));
  }

  Future<void> _addPhotos() async {
    final target = _target;
    if (target == null) return;
    final pages = await widget.sources.photos(context, target);
    if (pages == null || pages.isEmpty || !mounted) return;
    final n = _items.where((i) => i.photos != null).length + 1;
    setState(() => _items.add(_Item(_keys++, name: 'Paper from photos $n', named: false, pages: pages.length, photos: pages)));
  }

  /// "Add another paper": PDFs or photos.
  Future<void> _addMore() async {
    final choice = await showCentredCard<String>(
      context,
      title: 'Add a paper',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        RowTile(leading: Icon(Ph.filePdf, size: 22, color: ink), title: 'Choose PDFs', meta: 'Pick as many as you like', chevron: true, onTap: () => Navigator.of(ctx).pop('pdf')),
        const SizedBox(height: 10),
        RowTile(leading: Icon(Ph.camera, size: 22, color: ink), title: 'Photos of a paper', meta: 'Take them now or use ones you already took', chevron: true, onTap: () => Navigator.of(ctx).pop('photos')),
      ]),
    );
    if (choice == 'pdf') {
      await _addPdfs();
    } else if (choice == 'photos') {
      await _addPhotos();
    }
  }

  /// No paper to read: AI writes the test from what the tutor tells it.
  Future<void> _writeWithAi() async {
    final target = _target;
    if (target == null) return;
    await context.push(target.chatPath);
  }

  // ---------------------------------------------------------------- the working

  /// Makes the papers on the server with their plans and starts reading them.
  void _start() {
    // Every paper keeps the day it was given, so leaving one out later moves no other.
    for (final (i, it) in _items.indexed) {
      it
        ..day = _dayOf(i)
        ..planned = _plan(i)
        ..stage = _Stage.waiting
        ..error = null;
    }
    setState(() => _step = _Step.work);
    _runAll();
  }

  Future<void> _runAll() async {
    if (_running) return;
    _running = true;
    _stop = false;
    _tick();
    try {
      for (final it in List.of(_items)) {
        if (_stop || !mounted) break;
        if (it.stage == _Stage.read || _statusOf(it) == _Status.posted) continue;
        await _work(it);
      }
    } finally {
      _running = false;
      _tick();
    }
  }

  Future<void> _work(_Item it) async {
    it.error = null;
    try {
      if (it.id == null) await _send(it);
      if (_stop) return;
      it.stage = _Stage.reading;
      it.status = null;
      _tick();
      final r = it.runner ??= PaperRunner(it.id!, onChange: _tick);
      await r.run();
      if (_stop) return;
      if (r.problem != null) {
        it.stage = _Stage.failed;
        it.error = r.problem;
      } else {
        it.stage = _Stage.read;
      }
    } on ApiException catch (e) {
      it.stage = _Stage.failed;
      it.error = e.message;
    } catch (_) {
      it.stage = _Stage.failed;
      it.error = 'Something went wrong. Please try again.';
    }
    _tick();
  }

  /// Draws a PDF's pages, makes the paper with its plan and uploads every page.
  Future<void> _send(_Item it) async {
    final target = _target!;
    it.stage = _Stage.preparing;
    it.status = 'Preparing';
    _tick();
    final List<Uint8List> pages;
    if (it.photos != null) {
      pages = it.photos!;
    } else {
      pages = await widget.sources.render(await it.pdf!.read(), maxPaperPages, (i, n) {
        it.status = 'Preparing page $i of $n';
        _tick();
      });
      if (pages.isEmpty) throw ApiException(0, 'pdf', 'This PDF could not be opened. Try photographing the pages instead.');
    }
    try {
      final r = await api.post('/teacher/papers', {
        'pages': pages.length,
        // Each page's size, so storage takes exactly that many bytes for it.
        'sizes': [for (final p in pages) p.length],
        if (it.named) 'exam_name': it.name,
        if (target.isCourse) 'course_id': target.courseId else ...{'class_level': target.classLevel, 'subject_id': target.subjectId},
        'plan': it.planned!.toJson(),
      });
      it.id = '${r['paper']['id']}';
      final uploads = (r['uploads'] as List).cast<Map<String, dynamic>>();
      it.stage = _Stage.uploading;
      var done = 0;
      await forEachLimited(uploads, 3, (u) async {
        final n = u['page_no'] as int;
        await api.putBytes('${u['put_url']}', pages[n - 1]);
        await api.post('/teacher/papers/${it.id}/pages/$n/uploaded');
        done++;
        it.status = 'Uploading page ${math.min(done + 1, uploads.length)} of ${uploads.length}';
        _tick();
      });
      it.sent = true;
    } catch (_) {
      // A paper that did not arrive whole is taken back, so trying again starts clean.
      final half = it.id;
      it.id = null;
      if (half != null) unawaited(api.delete('/teacher/papers/$half').then<void>((_) {}, onError: (_) {}));
      rethrow;
    }
  }

  Future<void> _retry(_Item it) async {
    it.stage = _Stage.waiting;
    it.error = null;
    _tick();
    await _runAll();
  }

  /// Takes a paper out of the list (and off the server) when it cannot be used.
  Future<void> _leaveOut(_Item it) async {
    final id = it.id;
    it.runner?.stop();
    setState(() => _items.remove(it));
    if (id != null) unawaited(api.delete('/teacher/papers/$id').then<void>((_) {}, onError: (_) {}));
  }

  _Status _statusOf(_Item it) {
    final facts = it.runner?.facts;
    if (it.posted || (facts?.posted ?? false)) return _Status.posted;
    switch (it.stage) {
      case _Stage.waiting || _Stage.preparing || _Stage.uploading || _Stage.reading:
        return _Status.working;
      case _Stage.failed:
        return _Status.failed;
      case _Stage.read:
        if (facts == null) return _Status.working;
        if (facts.postable) return _Status.ready;
        if (facts.toCheck > 0 || facts.workLeft) return _Status.check;
        return _Status.empty;
    }
  }

  _Phase get _phase {
    if (_running) return _Phase.reading;
    final open = _items.where((i) => _statusOf(i) != _Status.posted).toList();
    if (open.isEmpty) return _Phase.done;
    if (open.every((i) => _statusOf(i) == _Status.ready)) return _Phase.ready;
    return _Phase.check;
  }

  String _label(_Item it) {
    final named = it.runner?.facts.paper['exam_name'];
    return named == null || '$named'.isEmpty ? it.name : '$named';
  }

  Future<void> _open(_Item it) async {
    if (it.id == null) return;
    await context.push('/t/papers/${it.id}');
    try {
      await it.runner?.load();
    } on ApiException {
      // The list shows what it had.
    }
    _tick();
  }

  // ---------------------------------------------------------------- posting

  Future<void> _post() async {
    final todo = [for (final it in _items) if (_statusOf(it) == _Status.ready) it];
    if (todo.isEmpty) return;
    setState(() => _posting = true);
    final failed = <String>[];
    for (final it in todo) {
      if (!mounted) return;
      try {
        await _postOne(it);
      } on ApiException catch (e) {
        failed.add('${_label(it)}: ${e.message}');
      } catch (_) {
        failed.add('${_label(it)}: Something went wrong. Please try again.');
      }
    }
    if (!mounted) return;
    setState(() => _posting = false);
    if (failed.isNotEmpty) await showProblem(context, ApiException(0, 'post', failed.join('\n')));
  }

  /// Saves the paper's questions, makes the test as planned and posts it. A paper that already has a test is not given a second one:
  /// a draft made on an earlier try is posted, and a posted one is left as it is.
  Future<void> _postOne(_Item it) async {
    final target = _target!;
    final id = it.id!;
    await api.post('/teacher/papers/$id/save');
    final d = await api.get('/teacher/papers/$id');
    final questions = (d['questions'] as List).cast<Map<String, dynamic>>();
    final tests = ((d['tests'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final title = '${(d['paper'] as Map)['exam_name']}';
    final plan = it.planned!;
    final limit = plan.limit ?? suggestedLimit(questions.length);
    if (tests.any((t) => t['status'] == 'published')) {
      it.posted = true;
      return;
    }
    final draft = tests.where((t) => t['status'] != 'published').firstOrNull;
    if (draft == null) {
      if (questions.isEmpty) throw ApiException(0, 'no_questions', 'The bank has all the questions of "$title" already, so there is no new test to make.');
      if (plan.closes.isBefore(DateTime.now().add(const Duration(minutes: 1)))) {
        throw ApiException(0, 'past', 'The closing time you chose for "$title" has passed. Open it from Home to post it with a new time.');
      }
    }
    final String testId;
    if (draft != null) {
      testId = '${draft['id']}';
    } else {
      final r = await api.post('/teacher/tests', {
        'title': title,
        if (target.isCourse) 'course_id': target.courseId else ...{'class_level': target.classLevel, 'subject_id': target.subjectId, 'assign_all': false, 'assign_group': true},
        'question_ids': [for (final q in questions) q['id']],
        'time_limit_min': limit,
        if (plan.opens != null) 'opens_at': plan.opens!.toUtc().toIso8601String(),
        'closes_at': plan.closes.toUtc().toIso8601String(),
        'shuffle': plan.shuffle,
        'paper_id': id,
      });
      testId = '${r['id']}';
    }
    await api.post('/teacher/tests/$testId/publish', {'published': true});
    it
      ..posted = true
      ..questions = questions.length
      ..limit = limit;
    try {
      await it.runner?.load();
    } on ApiException {
      // Posted all the same.
    }
  }

  // ---------------------------------------------------------------- leaving

  Future<void> _back() async {
    switch (_step) {
      case _Step.which:
        Navigator.of(context).pop();
      case _Step.papers:
        if (_asked) {
          setState(() => _step = _Step.which);
        } else {
          Navigator.of(context).pop();
        }
      case _Step.days:
        setState(() => _step = _Step.papers);
      case _Step.work:
        await _leave();
    }
  }

  Future<void> _leave() async {
    if (_phase == _Phase.done) {
      Navigator.of(context).pop();
      return;
    }
    final ok = await confirmCard(
      context,
      title: 'Leave this page?',
      body: _running
          ? 'AI stops reading. The papers are kept: open them from Home, under Needs you, and AI carries on where it stopped. Their days are remembered.'
          : 'The papers are kept: open them from Home, under Needs you, to check and post them. Their days are remembered.',
      confirm: 'Leave',
      cancel: 'Stay',
    );
    if (!ok || !mounted) return;
    _stopAll();
    Navigator.of(context).pop();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final Widget page = switch (_step) {
      _Step.which => _whichStep(),
      _Step.papers => _papersStep(),
      _Step.days => _daysStep(),
      _Step.work => switch (_phase) {
          _Phase.reading => _readingStep(),
          _Phase.check => _checkStep(),
          _Phase.ready => _readyStep(),
          _Phase.done => _doneStep(),
        },
    };
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: page,
    );
  }

  String _kicker(int step) => '${_target?.name ?? 'Make tests'} · Step $step of 4';

  /// A button with a short line of help under it. A button that cannot be used says why instead.
  Widget _footer(Widget button, [String? caption]) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        button,
        if (caption != null) ...[const SizedBox(height: 9), Fig(caption, style: labelStyle, textAlign: TextAlign.center)],
      ]);

  Widget _head(int step, {String? line}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (line != null) ...[const SizedBox(height: 14), Fig(line, style: bodyStyle.copyWith(color: muted))],
        const SizedBox(height: 16),
        _StepBar(step),
      ]);

  // ---------------------------------------------------------------- 1 which class

  Widget _whichStep() {
    final loading = _loadError == null && _targets.isEmpty;
    return PushedPanel(
      kicker: _kicker(1),
      kickerLines: 2,
      title: 'Which group or course are the tests for?',
      onBack: _back,
      footer: _footer(
        PrimaryButton(
          'Next',
          onTap: _picked == null
              ? null
              : () => setState(() {
                    _target = _picked;
                    _step = _Step.papers;
                  }),
        ),
        'Every paper you add becomes a test for this group or course.',
      ),
      children: [
        _head(1),
        const SizedBox(height: 20),
        if (_loadError != null)
          ErrorState(message: _loadError!, onRetry: _loadTargets)
        else if (loading)
          const LoadingState(rows: 3)
        else
          ...staggered([
            for (final (i, t) in _targets.indexed) ...[
              if (i > 0) const SizedBox(height: gapRow),
              RowTile(
                leading: _Radio(selected: identical(t, _picked)),
                title: t.name,
                meta: '${t.sizeLabel} · ${t.isCourse ? 'course' : 'group'}',
                onTap: () => setState(() => _picked = t),
              ),
            ],
          ], scope: this, prefix: 'which', stepMs: 45),
      ],
    );
  }

  // ---------------------------------------------------------------- 2 add the papers

  Widget _papersStep() {
    final n = _items.length;
    final pages = _items.fold<int>(0, (s, i) => s + i.pages);
    final big = _textScale(context) > 1.5;
    return PushedPanel(
      kicker: _kicker(2),
      kickerLines: 2,
      title: 'Add the papers',
      onBack: _back,
      footer: _footer(
        PrimaryButton(
          'Next: choose the days',
          onTap: n == 0 || _adding ? null : () => setState(() => _step = _Step.days),
          disabledReason: n == 0 ? 'Add at least one paper.' : null,
        ),
        n == 0 ? null : '${f.count(n, 'paper')} · ${f.count(pages, 'page')}',
      ),
      children: [
        _head(2, line: n == 0 ? 'Pick all the PDFs at once. Each one becomes its own test. Put the answer key at the end of a paper if it has one.' : 'Each paper becomes its own test.'),
        const SizedBox(height: 22),
        if (n == 0) ...[
          PrimaryButton('Choose PDFs', leadingIcon: Ph.filePdf, busy: _adding, onTap: _addPdfs),
          const SizedBox(height: 12),
          SecondaryButton('Add a paper from photos', icon: Ph.camera, onTap: _adding ? null : _addPhotos),
          const SizedBox(height: 18),
          Center(child: _AiLink(onTap: _writeWithAi)),
        ] else ...[
          SectionRule('Papers', count: n, padding: const EdgeInsets.fromLTRB(0, 0, 0, 12)),
          for (final (i, it) in _items.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              // At very large text the little file icon goes, so a name breaks between words and not inside one.
              leading: big ? null : _FileTile(photos: it.photos != null),
              titleWidget: Fig(it.name, style: rowTitleStyle, maxLines: big ? 4 : 2),
              meta: [f.count(it.pages, 'page'), ?it.note].join(' · '),
              trailing: CircleBtn(icon: Ph.x, size: 32, ground: fill, label: 'Remove ${it.name}', onTap: _adding ? null : () => setState(() => _items.remove(it))),
            ),
          ],
          const SizedBox(height: 14),
          if (n < _maxPapers)
            SecondaryButton('Add another paper', icon: Ph.plus, onTap: _adding ? null : _addMore)
          else
            Center(child: Fig('Ten papers at a time is the most.', style: labelStyle)),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------- 3 choose the days

  Future<void> _pickFirst() async {
    final today = _today;
    final c = await showChoices<int>(
      context,
      title: 'First test on',
      options: [for (var i = 0; i < 60; i++) Choice(i, f.dayTitle(DateTime(today.year, today.month, today.day + i)))],
      selected: _first.difference(today).inDays,
    );
    if (c?.value == null) return;
    setState(() => _first = DateTime(today.year, today.month, today.day + c!.value!));
  }

  Future<void> _pickDay(int i) async {
    final today = _today;
    final c = await showChoices<int>(
      context,
      title: 'Day of ${_items[i].name}',
      options: [for (var d = 0; d < 60; d++) Choice(d, f.dayTitle(DateTime(today.year, today.month, today.day + d)))],
      selected: _dayOf(i).difference(today).inDays,
    );
    if (c?.value == null) return;
    final day = DateTime(today.year, today.month, today.day + c!.value!);
    final follows = DateTime(_first.year, _first.month, _first.day + i);
    setState(() => _items[i].day = day == follows ? null : day);
  }

  Future<void> _changeShared() async {
    final r = await showCentredCard<_FormResult>(
      context,
      title: 'Every test',
      subtitle: 'For the tests that do not have times of their own.',
      builder: (ctx) => _TimesForm(initial: _shared, saveLabel: 'Save'),
    );
    if (r?.times == null) return;
    setState(() => _shared = r!.times!);
  }

  Future<void> _changeOwn(int i) async {
    final it = _items[i];
    final r = await showCentredCard<_FormResult>(
      context,
      title: it.name,
      subtitle: 'Test ${i + 1} of ${_items.length} · ${f.count(it.pages, 'page')}',
      builder: (ctx) => _TimesForm(initial: _timesOf(i), name: it.name, day: _dayOf(i), today: _today, saveLabel: 'Save', canShare: true),
    );
    if (r == null) return;
    setState(() {
      if (r.name != null && r.name!.trim().isNotEmpty && r.name!.trim() != it.name) {
        it
          ..name = r.name!.trim()
          ..named = true;
      }
      if (r.useShared) {
        it.own = null;
      } else if (r.times != null) {
        it.own = r.times == _shared ? null : r.times;
      }
      if (r.day != null) {
        final follows = DateTime(_first.year, _first.month, _first.day + i);
        it.day = r.day == follows ? null : r.day;
      }
    });
  }

  Widget _daysStep() {
    final n = _items.length;
    final bad = [for (var i = 0; i < n; i++) if (_problem(i) != null) i];
    final big = _textScale(context) > 1.35;
    final sharedText = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Fig('Every test: ${_range(_shared)}', style: rowTitleStyle.copyWith(fontSize: 14.5), numColor: ink),
      const SizedBox(height: 2),
      Fig('${_limitWords(_shared.limit)} · ${_shared.shuffle ? 'shuffled' : 'same order for all'}', style: labelStyle),
    ]);
    return PushedPanel(
      kicker: _kicker(3),
      kickerLines: 2,
      title: 'Choose the days',
      onBack: _back,
      footer: _footer(
        PrimaryButton(
          n == 1 ? 'Read the paper with AI' : 'Read the $n papers with AI',
          leadingIcon: Ph.scan,
          onTap: bad.isEmpty ? _start : null,
          disabledReason: bad.isEmpty ? null : 'Test ${bad.first + 1} ${_problem(bad.first)}. Change its day or its times.',
        ),
        'AI reads each paper and looks for the answers.',
      ),
      children: [
        _head(3, line: 'Each paper becomes a test on its own day.'),
        const SizedBox(height: 20),
        if (big)
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('First test on', style: rowTitleStyle),
            const SizedBox(height: 8),
            SelectPill(label: f.shortDate(_first), onTap: _pickFirst),
          ])
        else
          Row(children: [
            Expanded(child: Text('First test on', style: rowTitleStyle)),
            SelectPill(label: f.shortDate(_first), onTap: _pickFirst),
          ]),
        const SizedBox(height: 14),
        Pressable(
          label: 'Every test: ${_range(_shared)}. Change',
          onTap: _changeShared,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rCard)),
            // At large text, Change sits under the times instead of squeezing them.
            child: big
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Ph.clock, size: 20, color: muted)),
                      const SizedBox(width: 12),
                      Expanded(child: sharedText),
                    ]),
                    Padding(padding: const EdgeInsets.only(left: 28), child: TextAction('Change', color: ink, onTap: _changeShared)),
                  ])
                : Row(children: [
                    Icon(Ph.clock, size: 20, color: muted),
                    const SizedBox(width: 12),
                    Expanded(child: sharedText),
                    const SizedBox(width: 6),
                    TextAction('Change', color: ink, onTap: _changeShared),
                  ]),
          ),
        ),
        const SizedBox(height: 14),
        for (final (i, it) in _items.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          _DayRow(
            title: it.name,
            line: _problem(i) != null
                ? 'It ${_problem(i)}. Change its day or its times.'
                : it.own == null
                    ? _range(_shared)
                    : [_range(it.own!), if (it.own!.limit != null) '${it.own!.limit} min', if (!it.own!.shuffle) 'same order for all'].join(' · '),
            lineColor: _problem(i) != null ? danger : (it.own == null ? null : warning),
            day: f.shortDate(_dayOf(i)),
            onTap: () => _changeOwn(i),
            onDay: () => _pickDay(i),
          ),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------- 4 reading

  Widget _readingStep() {
    final n = _items.length;
    final read = _items.where((i) => i.stage == _Stage.read || _statusOf(i) == _Status.posted).length;
    var found = 0;
    var worked = 0;
    DateTime? busyUntil;
    for (final it in _items) {
      final facts = it.runner?.facts;
      if (facts == null) continue;
      found += facts.mcq;
      worked += facts.answered + facts.saved;
      final b = it.runner?.busyUntil;
      if (b != null && b.isAfter(DateTime.now()) && (busyUntil == null || b.isAfter(busyUntil))) busyUntil = b;
    }
    return PushedPanel(
      kicker: _kicker(4),
      kickerLines: 2,
      title: 'Reading your papers',
      onBack: _back,
      footer: _footer(PrimaryButton('Post the tests', onTap: null, disabledReason: 'Posting opens when every paper is read.')),
      children: [
        _head(4),
        const SizedBox(height: 20),
        AiProgressCard(
          done: read,
          total: n,
          unit: n == 1 ? 'paper read' : 'papers read',
          line: found == 0 ? 'Getting the first paper ready.' : '${f.count(found, 'question')} found, ${f.count(worked, 'answer')} worked out.',
        ),
        if (busyUntil != null) ...[
          const SizedBox(height: 12),
          const InlineNotice('AI has used its limit for a minute. It carries on by itself.', tone: Tone.ai, icon: Ph.clock),
        ],
        SectionRule('Papers', count: n, padding: const EdgeInsets.fromLTRB(0, 26, 0, 12)),
        Surface(
          shadow: e1,
          child: Column(children: [
            for (final (i, it) in _items.indexed)
              Container(
                decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: hairline))),
                child: _StageRow(item: it, label: _label(it), onRetry: () => _retry(it), onLeaveOut: () => _leaveOut(it)),
              ),
          ]),
        ),
        const SizedBox(height: 16),
        Fig('Keep the app open while AI reads. If you leave, it carries on where it stopped when you come back.', style: labelStyle, textAlign: TextAlign.center),
      ],
    );
  }

  // ---------------------------------------------------------------- 4 check and post

  Widget _checkStep() {
    final n = _items.length;
    final ready = _items.where((i) => _statusOf(i) == _Status.ready).length;
    final posted = _items.where((i) => _statusOf(i) == _Status.posted).length;
    final waiting = n - posted - ready;
    final Widget footer;
    if (ready > 0) {
      footer = _footer(
        PrimaryButton(ready == 1 ? 'Post the paper that is ready' : 'Post the $ready that are ready', busy: _posting, onTap: _post),
        waiting == 1 ? 'The other paper waits here until you check it.' : 'The other $waiting wait here until you check them.',
      );
    } else if (posted > 0) {
      footer = _footer(PrimaryButton('Back to Home', onTap: () => Navigator.of(context).pop()), 'What is left is under Needs you on Home.');
    } else {
      footer = _footer(PrimaryButton('Post the tests', onTap: null, disabledReason: 'Tap a paper above to check it first.'));
    }
    return PushedPanel(
      kicker: _kicker(4),
      kickerLines: 2,
      title: 'Check and post',
      onBack: _back,
      footer: footer,
      children: [
        _head(4),
        const SizedBox(height: 18),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 5), child: Container(width: 8, height: 8, decoration: BoxDecoration(color: waiting > 0 ? warning : success, shape: BoxShape.circle))),
          const SizedBox(width: 9),
          Expanded(
            child: Text.rich(TextSpan(style: bodyStyle.copyWith(color: muted), children: [
              TextSpan(text: '${ready + posted} of $n ${ready + posted == 1 && n == 1 ? 'is' : 'are'} ready', style: bodyStyle.copyWith(fontWeight: FontWeight.w700, color: ink)),
              if (waiting > 0) const TextSpan(text: ' · tap a paper to check what it needs'),
            ])),
          ),
        ]),
        const SizedBox(height: 14),
        Surface(
          shadow: e1,
          child: Column(children: [
            for (final (i, it) in _items.indexed)
              Container(
                decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: hairline))),
                child: _CheckRow(
                  item: it,
                  label: _label(it),
                  status: _statusOf(it),
                  facts: it.runner?.facts,
                  day: _dayOf(i),
                  onTap: () => _open(it),
                  onRetry: () => _retry(it),
                  onLeaveOut: () => _leaveOut(it),
                ),
              ),
          ]),
        ),
        if (_posting) ...[const SizedBox(height: 14), Fig('Posting', style: labelStyle, textAlign: TextAlign.center)],
      ],
    );
  }

  // ---------------------------------------------------------------- 4 ready to post

  String get _who {
    final t = _target!;
    if (t.size == 0) return t.name;
    return t.isCourse ? 'the ${t.size} ${t.size == 1 ? 'person' : 'people'} in ${t.name}' : 'the ${t.size} ${t.size == 1 ? 'student' : 'students'} in ${t.name}';
  }

  List<Widget> _week(Iterable<_Item> items) {
    final list = items.toList();
    return [
      SectionRule('The week', count: list.length, padding: const EdgeInsets.fromLTRB(0, 22, 0, 12)),
      Surface(
        shadow: e1,
        child: Column(children: [
          for (final (i, it) in list.indexed)
            Container(
              decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: hairline))),
              child: _WeekRow(day: _dayOf(_items.indexOf(it)), title: _label(it), details: _detailsOf(it)),
            ),
        ]),
      ),
    ];
  }

  /// "20 questions · 30 min · 8:00 am to 9:00 pm".
  String _detailsOf(_Item it) {
    final facts = it.runner?.facts;
    final questions = it.questions ?? (facts == null ? 0 : (facts.ready + facts.saved));
    final plan = it.planned!;
    final limit = it.limit ?? plan.limit ?? suggestedLimit(questions);
    final i = _items.indexOf(it);
    final t = i < 0 ? _shared : _timesOf(i);
    return '${f.count(questions, 'question')} · $limit min · ${_range(t)}';
  }

  Widget _readyStep() {
    final open = _items.where((i) => _statusOf(i) != _Status.posted).toList();
    final n = open.length;
    return PushedPanel(
      kicker: _kicker(4),
      kickerLines: 2,
      title: 'Ready to post',
      onBack: _back,
      footer: _footer(
        PrimaryButton(n == 1 ? 'Post 1 test' : 'Post $n tests', leadingIcon: Ph.exam, busy: _posting, onTap: _post),
        'You can change a test later from Home.',
      ),
      children: [
        _head(4, line: 'Each test opens on its day for $_who.'),
        ..._week(open),
        const SizedBox(height: 16),
        if (_target!.size == 0)
          InlineNotice(
            _target!.isCourse ? 'No one is in ${_target!.name} yet, so nobody would see these. Add people to the course first.' : 'No student is in ${_target!.name} yet, so nobody would see these. Add students to the group first.',
            icon: Ph.warning,
          )
        else
          const InlineNotice('Students see their marks and the right answers as soon as they hand a test in.', tone: Tone.neutral, icon: Ph.info),
      ],
    );
  }

  // ---------------------------------------------------------------- done

  Widget _doneStep() {
    final done = _items.where((i) => i.posted || (i.runner?.facts.posted ?? false)).toList();
    final n = done.length;
    final opens = [for (final it in done) (it.planned?.opens ?? it.planned?.closes ?? DateTime.now())]..sort();
    final first = opens.isEmpty ? null : opens.first;
    final last = opens.isEmpty ? null : opens.last;
    final when = first == null
        ? ''
        : (f.shortDate(first) == f.shortDate(last!) ? 'They open on ${f.shortDate(first)}.' : 'They open on their days, from ${f.shortDate(first)} to ${f.shortDate(last)}.');
    final upcoming = done.any((i) => i.planned?.opens != null);
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(gutter, 56, gutter, 24), children: [
              ...staggered([
                Center(
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(color: successSoft, shape: BoxShape.circle),
                    child: Icon(Ph.check, size: 32, color: success),
                  ),
                ),
                const SizedBox(height: 20),
                Text(n == 1 ? '1 test is set' : '$n tests are set', style: cardTitleStyle, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Fig('$when${upcoming ? ' You will find ${n == 1 ? 'it' : 'them'} under Coming up on Home.' : ' You will find ${n == 1 ? 'it' : 'them'} on Home.'}', style: bodyStyle.copyWith(color: muted), textAlign: TextAlign.center),
                if (_items.length > n) ...[
                  const SizedBox(height: 12),
                  InlineNotice('${f.count(_items.length - n, 'paper')} still ${_items.length - n == 1 ? 'needs' : 'need'} you. ${_items.length - n == 1 ? 'It is' : 'They are'} under Needs you on Home.', icon: Ph.info, tone: Tone.neutral),
                ],
              ], scope: this, prefix: 'done', stepMs: 70),
              ..._week(done),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 4, gutter, 12),
            child: PrimaryButton(widget.target != null ? 'Back to ${widget.target!.name}' : 'Back to Home', onTap: () => Navigator.of(context).pop()),
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- small pieces

/// How much bigger than usual the phone's text is: 1.0 at the usual size, 2.0 at twice that.
double _textScale(BuildContext context) => MediaQuery.textScalerOf(context).scale(15) / 15;

/// Four short bars: how far along the four steps the tutor is.
class _StepBar extends StatelessWidget {
  const _StepBar(this.step);
  final int step;

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Step $step of 4',
        child: Row(children: [
          for (var i = 1; i <= 4; i++) ...[
            if (i > 1) const SizedBox(width: 6),
            Expanded(
              child: AnimatedContainer( // motion: approved
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                height: 3,
                decoration: BoxDecoration(color: i <= step ? ink : hairline, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ],
        ]),
      );
}

/// The choice in a list of classes: a ring, filled with a tick for the one chosen.
class _Radio extends StatelessWidget {
  const _Radio({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) => AnimatedContainer( // motion: approved
        duration: const Duration(milliseconds: 160),
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? actionFill : Colors.transparent,
          border: selected ? null : Border.all(color: ringIdle, width: 1.6),
        ),
        child: selected ? Icon(Ph.check, size: 14, color: actionInk) : null,
      );
}

/// A paper's little icon: a PDF or photos.
class _FileTile extends StatelessWidget {
  const _FileTile({required this.photos});
  final bool photos;

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(12)),
        child: Icon(photos ? Ph.images : Ph.filePdf, size: 20, color: muted),
      );
}

/// "No paper? Let AI write a test."
class _AiLink extends StatelessWidget {
  const _AiLink({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: 'No paper? Let AI write a test',
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Ph.scan, size: 18, color: aiAccentInk),
            const SizedBox(width: 8),
            Flexible(
              child: Text.rich(TextSpan(style: bodyStyle.copyWith(color: muted, fontSize: 14), children: [
                const TextSpan(text: 'No paper? '),
                TextSpan(text: 'Let AI write a test', style: bodyStyle.copyWith(fontWeight: FontWeight.w700, color: ink, fontSize: 14)),
              ])),
            ),
          ]),
        ),
      );
}

/// One paper on the days step: its name and times, and the day it is on.
class _DayRow extends StatelessWidget {
  const _DayRow({required this.title, required this.line, this.lineColor, required this.day, required this.onTap, required this.onDay});
  final String title;
  final String line;
  final Color? lineColor;
  final String day;
  final VoidCallback onTap;
  final VoidCallback onDay;

  @override
  Widget build(BuildContext context) {
    final dayPill = Pressable(
      label: 'Day: $day',
      onTap: onDay,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 8, 9),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Fig(day, style: chipStyle.copyWith(color: ink, fontWeight: FontWeight.w600)),
          const SizedBox(width: 5),
          Icon(Ph.caretDown, size: 13, color: faint),
        ]),
      ),
    );
    final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
    return LayoutBuilder(builder: (context, box) {
      final stacked = scale > 1.35 || box.maxWidth < 330;
      final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Fig(title, style: rowTitleStyle, maxLines: stacked ? 4 : 2),
        const SizedBox(height: 2),
        Fig(line, style: labelStyle.copyWith(color: lineColor)),
      ]);
      return Pressable(
        label: '$title. $line',
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(17, 13, 7, 13),
          decoration: surface(radius: rCard, shadow: e1),
          child: stacked
              ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, const SizedBox(height: 6), Align(alignment: Alignment.centerLeft, child: Transform.translate(offset: const Offset(-10, 0), child: dayPill))])
              : Row(crossAxisAlignment: CrossAxisAlignment.center, children: [Expanded(child: text), const SizedBox(width: 8), dayPill]),
        ),
      );
    });
  }
}

enum _RingKind { done, working, failed, check, idle }

class _Ring extends StatelessWidget {
  const _Ring(this.kind);
  final _RingKind kind;

  @override
  Widget build(BuildContext context) => switch (kind) {
        _RingKind.done => Container(
            width: 21,
            height: 21,
            decoration: BoxDecoration(color: success, shape: BoxShape.circle),
            child: const Icon(Ph.check, size: 13, color: Colors.white),
          ),
        _RingKind.working => Breathe(
            child: Container(
              width: 21,
              height: 21,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: aiAccentInk, width: 1.8)),
              child: Container(width: 7, height: 7, decoration: BoxDecoration(color: aiAccentInk, shape: BoxShape.circle)),
            ),
          ),
        _RingKind.failed => Container(
            width: 21,
            height: 21,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: danger, width: 1.8)),
            child: Icon(Ph.x, size: 12, color: danger),
          ),
        _RingKind.check => Container(
            width: 21,
            height: 21,
            alignment: Alignment.center,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: warning, width: 1.8)),
            child: Container(width: 7, height: 7, decoration: BoxDecoration(color: warning, shape: BoxShape.circle)),
          ),
        _RingKind.idle => Container(width: 21, height: 21, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ringIdle, width: 1.8))),
      };
}

/// A paper while it is sent and read: waiting, uploading, being read, read, or not read.
class _StageRow extends StatelessWidget {
  const _StageRow({required this.item, required this.label, required this.onRetry, required this.onLeaveOut});
  final _Item item;
  final String label;
  final VoidCallback onRetry;
  final VoidCallback onLeaveOut;

  @override
  Widget build(BuildContext context) {
    final facts = item.runner?.facts;
    final ready = item.stage == _Stage.read || (facts?.posted ?? false);
    final (_RingKind ring, String line, String? word, Color? wordColor) = switch (item.stage) {
      _ when ready => (_RingKind.done, facts == null ? 'Read' : f.count(facts.mcq, 'question'), 'read', success),
      _Stage.waiting => (_RingKind.idle, 'Waiting', null, null),
      _Stage.preparing || _Stage.uploading => (_RingKind.working, item.status ?? 'Preparing', 'sending', aiAccentInk),
      _Stage.reading => (
          _RingKind.working,
          facts == null || facts.pageCount == 0
              ? 'Reading'
              : facts.pagesRead >= facts.pageCount
                  ? 'Working out the answers'
                  : 'Reading page ${facts.pagesRead + 1} of ${facts.pageCount}',
          'reading',
          aiAccentInk,
        ),
      _Stage.failed => (_RingKind.failed, item.error ?? 'This paper could not be read.', null, null),
      _ => (_RingKind.idle, 'Waiting', null, null),
    };
    final failed = item.stage == _Stage.failed;
    final big = _textScale(context) > 1.35;
    return Padding(
      padding: const EdgeInsets.fromLTRB(17, 13, 12, 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: _Ring(ring)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Fig(label, style: rowTitleStyle.copyWith(color: item.stage == _Stage.waiting ? muted : ink), maxLines: big ? 4 : 2),
            const SizedBox(height: 2),
            Fig(line, style: labelStyle.copyWith(color: failed ? danger : null)),
            if (big && word != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(word, style: numStyle(size: 11.5, color: wordColor ?? muted))),
            if (failed) Row(children: [
              TextAction('Try again', color: ink, onTap: onRetry),
              const SizedBox(width: 8),
              TextAction('Leave out', onTap: onLeaveOut),
            ]),
          ]),
        ),
        if (!big && word != null) ...[const SizedBox(width: 10), Padding(padding: const EdgeInsets.only(top: 2), child: Text(word, style: numStyle(size: 11.5, color: wordColor ?? muted)))],
      ]),
    );
  }
}

/// A paper once everything is read: ready, needing the tutor, not readable, or posted.
class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.item,
    required this.label,
    required this.status,
    required this.facts,
    required this.day,
    required this.onTap,
    required this.onRetry,
    required this.onLeaveOut,
  });
  final _Item item;
  final String label;
  final _Status status;
  final PaperFacts? facts;
  final DateTime day;
  final VoidCallback onTap;
  final VoidCallback onRetry;
  final VoidCallback onLeaveOut;

  @override
  Widget build(BuildContext context) {
    final questions = facts?.mcq ?? 0;
    final detail = switch (status) {
      _Status.failed => item.error ?? 'This paper could not be read.',
      _Status.empty => 'No multiple-choice questions found',
      _Status.posted => 'Posted · ${f.shortDate(item.planned?.opens ?? item.planned?.closes ?? day)}',
      _ => '${f.count(questions, 'question')} · ${f.shortDate(day)}',
    };
    final ring = switch (status) {
      _Status.ready || _Status.posted => _RingKind.done,
      _Status.check => _RingKind.check,
      _ => _RingKind.failed,
    };
    final toCheck = facts?.toCheck ?? 0;
    final Widget? tag = switch (status) {
      _Status.ready => Text('ready', style: numStyle(size: 11.5, color: success)),
      _Status.posted => Text('posted', style: numStyle(size: 11.5, color: success)),
      _Status.check => TagChip(toCheck > 0 ? '$toCheck to check' : 'to check', tone: Tone.warning),
      _ => null,
    };
    final tappable = status == _Status.check || status == _Status.ready;
    final big = _textScale(context) > 1.35;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(17, 13, 12, 13),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: _Ring(ring)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Fig(label, style: rowTitleStyle, maxLines: big ? 4 : 2),
            const SizedBox(height: 2),
            Fig(detail, style: labelStyle.copyWith(color: status == _Status.failed ? danger : null)),
            if (big && tag != null) Padding(padding: const EdgeInsets.only(top: 6), child: tag),
            if (status == _Status.failed || status == _Status.empty)
              Row(children: [
                if (status == _Status.failed) ...[TextAction('Try again', color: ink, onTap: onRetry), const SizedBox(width: 8)],
                TextAction('Leave out', onTap: onLeaveOut),
              ]),
          ]),
        ),
        if (!big && tag != null) ...[const SizedBox(width: 10), tag],
        if (status == _Status.check) ...[const SizedBox(width: 6), Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Ph.caretRight, size: 16, color: faint))],
      ]),
    );
    return tappable ? Pressable(label: '$label. $detail', onTap: onTap, child: row) : row;
  }
}

/// One test of the week: the day it opens, its name and how it runs.
class _WeekRow extends StatelessWidget {
  const _WeekRow({required this.day, required this.title, required this.details});
  final DateTime day;
  final String title;
  final String details;

  @override
  Widget build(BuildContext context) {
    final nameStyle = kickerStyle.copyWith(fontSize: 9.5, color: faint);
    final dateStyle = numStyle(size: 14, weight: FontWeight.w600);
    final weekday = DateFormat('EEE').format(day).toUpperCase();
    final date = '${day.day} ${DateFormat('MMM').format(day)}';
    return LayoutBuilder(builder: (context, box) {
      // The widest date sets the width of the date column, so every row lines up and no date breaks in two. When that column would
      // take more than a third of the row (large text on a small phone) the date sits above the name instead.
      final probe = TextPainter(text: TextSpan(text: '88 MMM', style: dateStyle), textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context), maxLines: 1)..layout();
      final tile = math.max(46.0, probe.width.ceilToDouble() + 2);
      probe.dispose();
      final stacked = tile > (box.maxWidth - 34) / 3;
      final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Fig(title, style: rowTitleStyle, maxLines: stacked ? 4 : 2),
        const SizedBox(height: 2),
        Fig(details, style: labelStyle),
      ]);
      return Padding(
        padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
        child: stacked
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [Text(weekday, style: nameStyle), Text(date, style: dateStyle)]),
                const SizedBox(height: 6),
                text,
              ])
            : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: tile,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(weekday, style: nameStyle),
                    const SizedBox(height: 2),
                    Text(date, style: dateStyle),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(child: text),
              ]),
      );
    });
  }
}

// ---------------------------------------------------------------- the times form

/// What a times form hands back.
class _FormResult {
  const _FormResult({this.name, this.day, this.times, this.useShared = false});
  final String? name;
  final DateTime? day;
  final _Times? times;
  final bool useShared;
}

/// The times of one test, or of every test: when it opens and closes, how long it takes, and the order of its questions. With a
/// [name] and a [day] it is the form of a single test.
class _TimesForm extends StatefulWidget {
  const _TimesForm({required this.initial, this.name, this.day, this.today, required this.saveLabel, this.canShare = false});
  final _Times initial;
  final String? name;
  final DateTime? day;
  final DateTime? today;
  final String saveLabel;

  /// Offers "Use the same as the others".
  final bool canShare;

  @override
  State<_TimesForm> createState() => _TimesFormState();
}

class _TimesFormState extends State<_TimesForm> {
  late _Times _t = widget.initial;
  late DateTime? _day = widget.day;
  late final TextEditingController _name = TextEditingController(text: widget.name ?? '');

  static final _clocks = [for (var m = 5 * 60; m <= 23 * 60 + 30; m += 30) m];
  static const _limits = [10, 15, 20, 30, 45, 60, 90, 120, 180];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final today = widget.today!;
    final c = await showChoices<int>(
      context,
      title: 'Day',
      options: [for (var d = 0; d < 60; d++) Choice(d, f.dayTitle(DateTime(today.year, today.month, today.day + d)))],
      selected: _day!.difference(today).inDays,
    );
    if (c?.value != null && mounted) setState(() => _day = DateTime(today.year, today.month, today.day + c!.value!));
  }

  Future<void> _pickClock(String title, int value, void Function(int) set) async {
    final c = await showChoices<int>(context, title: title, options: [for (final m in {..._clocks, value}.toList()..sort()) Choice(m, _clock(m))], selected: value);
    if (c?.value != null && mounted) setState(() => set(c!.value!));
  }

  Future<void> _pickLimit() async {
    final c = await showChoices<int>(
      context,
      title: 'Time limit',
      options: [
        const Choice(-1, 'Auto · 1½ minutes a question'),
        for (final m in {..._limits, ?_t.limit}.toList()..sort()) Choice(m, '$m min'),
      ],
      selected: _t.limit ?? -1,
    );
    if (c?.value != null && mounted) setState(() => _t = _t.withLimit(c!.value == -1 ? null : c.value));
  }

  @override
  Widget build(BuildContext context) {
    final backwards = _t.closes <= _t.opens;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.name != null) ...[
        const FormLabel('Name', top: 0),
        GroupedInputs(children: [BareField(controller: _name, placeholder: 'Name of the test', capitalization: TextCapitalization.sentences, maxLength: 80)]),
      ],
      if (_day != null) ...[
        const FormLabel('Day'),
        SelectField(value: f.dayTitle(_day!), onTap: _pickDay),
      ],
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FormLabel('Opens', top: widget.name == null ? 0 : 22),
            SelectField(value: _clock(_t.opens), onTap: () => _pickClock('Opens', _t.opens, (m) => _t = _t.copyWith(opens: m))),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FormLabel('Closes', top: widget.name == null ? 0 : 22),
            SelectField(value: _clock(_t.closes), onTap: () => _pickClock('Closes', _t.closes, (m) => _t = _t.copyWith(closes: m))),
          ]),
        ),
      ]),
      const FormLabel('Time limit'),
      SelectField(value: _limitWords(_t.limit), onTap: _pickLimit),
      const FormLabel('Order of the questions'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        SegChip('Shuffled', selected: _t.shuffle, onTap: () => setState(() => _t = _t.copyWith(shuffle: true))),
        SegChip('Same for all', selected: !_t.shuffle, onTap: () => setState(() => _t = _t.copyWith(shuffle: false))),
      ]),
      if (backwards) ...[const SizedBox(height: 14), const InlineNotice('The test has to close after it opens.', icon: Ph.warning)],
      const SizedBox(height: 20),
      PrimaryButton(widget.saveLabel, onTap: backwards ? null : () => Navigator.of(context).pop(_FormResult(name: widget.name == null ? null : _name.text, day: _day, times: _t))),
      if (widget.canShare) ...[
        const SizedBox(height: 8),
        Center(child: TextAction('Use the same as the others', onTap: () => Navigator.of(context).pop(_FormResult(name: _name.text, day: _day, useShared: true)))),
      ],
    ]);
  }
}
