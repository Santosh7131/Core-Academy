import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/api.dart';
import '../../core/pool.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import '../../ui/option_mark.dart';
import '../../ui/tokens.dart';
import 'common.dart';
import 'subjects.dart';
import 'questions_screens.dart' show MathToolbar, insertInto, pickAndUploadImage;

/// A paper's name, as AI found it or the teacher typed it.
String paperName(Map<String, dynamic> p) => '${p['exam_name']}';

/// "10th Science", or what is still unknown about a paper.
String paperGroup(Map<String, dynamic> p) {
  final cls = p['class_level'] as int?;
  if (cls == null) return 'Class not set';
  return p['subject'] == null ? 'Class $cls' : groupName(cls, '${p['subject']}');
}

/// The name a paper has before AI or the teacher names it (the API's placeholder).
const _unnamed = 'New paper';


// ---------------------------------------------------------------- upload

/// Pages first: AI works out the rest once they are uploaded.
class UploadPaperScreen extends StatefulWidget {
  /// From a group's page: the paper's class and subject are the group's.
  const UploadPaperScreen({super.key, this.classLevel, this.subjectId});
  final int? classLevel;
  final String? subjectId;

  @override
  State<UploadPaperScreen> createState() => _UploadPaperScreenState();
}

class _UploadPaperScreenState extends State<UploadPaperScreen> {
  final List<Uint8List> _pages = [];
  String? _status;
  bool _busy = false;

  Future<void> _camera() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 1600, imageQuality: 80);
    if (x != null) {
      final b = await x.readAsBytes();
      setState(() => _pages.add(b));
    }
  }

  Future<void> _gallery() async {
    final xs = await ImagePicker().pickMultiImage(maxWidth: 1600, imageQuality: 80);
    for (final x in xs) {
      _pages.add(await x.readAsBytes());
    }
    setState(() {});
  }

  /// Splits a PDF into page images on the phone (1600 px wide JPEGs).
  Future<void> _pdf() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (files.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Opening the PDF';
    });
    try {
      final doc = await PdfDocument.openData(await files.first.readAsBytes());
      final n = doc.pagesCount.clamp(0, 20 - _pages.length);
      for (var i = 1; i <= n; i++) {
        setState(() => _status = 'Preparing page $i of $n');
        final page = await doc.getPage(i);
        final scale = 1600 / page.width;
        final img = await page.render(
          width: page.width * scale,
          height: page.height * scale,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#FFFFFF',
          quality: 80,
        );
        await page.close();
        if (img != null) _pages.add(img.bytes);
      }
      await doc.close();
    } catch (_) {
      if (mounted) showProblem(context, ApiException(0, 'pdf', 'This PDF could not be opened. Try photographing the pages instead.'));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _status = 'Starting the paper';
    });
    try {
      final r = await api.post('/teacher/papers', {
        'pages': _pages.length,
        if (widget.classLevel != null) 'class_level': widget.classLevel,
        if (widget.subjectId != null) 'subject_id': widget.subjectId,
      });
      final id = '${r['paper']['id']}';
      final uploads = (r['uploads'] as List).cast<Map<String, dynamic>>();
      for (final u in uploads) {
        final n = u['page_no'] as int;
        setState(() => _status = 'Uploading page $n of ${uploads.length}');
        await api.putBytes('${u['put_url']}', _pages[n - 1]);
        await api.post('/teacher/papers/$id/pages/$n/uploaded');
      }
      if (mounted) context.pushReplacement('/t/papers/$id?read=1');
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final full = _pages.length >= 20;
    return PushedPanel(
      kicker: 'Question paper',
      title: 'Upload paper',
      footer: PrimaryButton(
        _status ?? 'Read with AI',
        leadingIcon: _busy ? null : Ph.scan,
        onTap: _pages.isNotEmpty && !_busy ? _upload : null,
        disabledReason: _busy ? null : (_pages.isEmpty ? 'Add at least one page.' : null),
      ),
      children: [
        const SizedBox(height: 14),
        Fig(
          'Add the pages, including the answer key if the paper has one. AI reads them, names the paper and marks the '
          'answers it can. You check everything before it is saved.',
          style: bodyStyle.copyWith(color: muted),
        ),
        FormLabel(_pages.isEmpty ? 'Pages' : 'Pages · ${_pages.length}'),
        if (_pages.isNotEmpty) ...[
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final (i, b) in _pages.indexed)
              Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 84,
                  height: 112,
                  decoration: surface(radius: rSmall, shadow: e1),
                  clipBehavior: Clip.antiAlias,
                  child: Image.memory(b, fit: BoxFit.cover),
                ),
                Positioned(left: 6, bottom: 6, child: TagChip('${i + 1}')),
                Positioned(
                  right: -8,
                  top: -8,
                  child: CircleBtn(icon: Ph.x, size: 30, label: 'Remove page ${i + 1}', onTap: _busy ? null : () => setState(() => _pages.removeAt(i))),
                ),
              ]),
          ]),
          const SizedBox(height: 14),
        ],
        Row(children: [
          Expanded(child: SecondaryButton('Camera', icon: Ph.camera, onTap: _busy || full ? null : _camera)),
          const SizedBox(width: 8),
          Expanded(child: SecondaryButton('Gallery', icon: Ph.images, onTap: _busy || full ? null : _gallery)),
          const SizedBox(width: 8),
          Expanded(child: SecondaryButton('PDF', icon: Ph.filePdf, onTap: _busy || full ? null : _pdf)),
        ]),
        const SizedBox(height: 10),
        Fig('Lay the paper flat in good light, with the whole page in the photo. Up to 20 pages.', style: labelStyle),
      ],
    );
  }
}

// ---------------------------------------------------------------- review

enum _Filter { toCheck, ready, byAi, other, saved, skipped, all }

const _filterLabels = {
  _Filter.toCheck: 'To check',
  _Filter.ready: 'Ready to save',
  _Filter.byAi: 'Answered by AI',
  _Filter.other: 'Not multiple choice',
  _Filter.saved: 'Saved',
  _Filter.skipped: 'Skipped',
  _Filter.all: 'All questions',
};

/// One uploaded paper. AI first works out its details (the teacher fills in what it could not
/// find), reads every page and looks for the answers; the teacher checks and saves. Once every
/// question is saved it shows the paper as a named set that can be published as a test.
class PaperReviewScreen extends StatefulWidget {
  const PaperReviewScreen({super.key, required this.id, this.autoRead = false});
  final String id;
  final bool autoRead;

  @override
  State<PaperReviewScreen> createState() => _PaperReviewScreenState();
}

class _PaperReviewScreenState extends State<PaperReviewScreen> {
  Map<String, dynamic>? _paper;
  List<Map<String, dynamic>> _pages = [];
  List<Map<String, dynamic>> _drafts = [];
  List<Map<String, dynamic>> _chapters = [];

  /// The questions saved from this paper, as they now are in the bank, in paper order.
  List<Map<String, dynamic>> _questions = [];

  /// Tests made from this paper, newest first.
  List<Map<String, dynamic>> _tests = [];
  String? _error;

  /// What AI is doing right now ("Reading page 2 of 4"), and why it last stopped.
  String? _working;
  String? _aiError;
  String? _answerNote;
  String? _saved;
  bool _saving = false;
  bool _making = false;
  bool _running = false;
  _Filter _filter = _Filter.toCheck;

  /// Each draft's latest marking, so a slow reply to an earlier tap cannot undo a later one.
  final Map<String, int> _markSeq = {};

  /// Looking at the AI drafts of a paper that is already a finished set.
  bool _review = false;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (widget.autoRead) _run();
    });
  }

  /// What the teacher still has to give: only the name. The class and subject are the group's.
  List<String> get _missing => ((_paper?['missing'] as List?) ?? const []).cast<String>().where((m) => m == 'exam_name').toList();

  Future<void> _load() async {
    try {
      final d = await api.get('/teacher/papers/${widget.id}');
      if (!mounted) return;
      setState(() {
        _paper = Map<String, dynamic>.from(d['paper']);
        _pages = (d['pages'] as List).cast<Map<String, dynamic>>();
        _drafts = (d['drafts'] as List).cast<Map<String, dynamic>>();
        _chapters = (d['chapters'] as List).cast<Map<String, dynamic>>();
        _questions = (d['questions'] as List? ?? const []).cast<Map<String, dynamic>>();
        _tests = (d['tests'] as List? ?? const []).cast<Map<String, dynamic>>();
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// How many pages are read at once, and how many batches of questions are answered at once.
  /// Gemini's free plan takes 15 page reads a minute, so reading four at a time stays inside that
  /// for a paper of up to a dozen pages (a longer one meets the limit, which AI waits out).
  static const _readWidth = 4;
  static const _answerWidth = 3;

  /// Progress of the run, for the line shown while AI works.
  int _pagesTotal = 0;
  int _pagesRead = 0;
  int _found = 0;

  /// When AI said it had used its limit: the latest time any waiting call carries on.
  DateTime? _busyUntil;

  /// The line shown while AI works; while any call is waiting out a limit it says so, with a countdown.
  String? get _workingText {
    final until = _busyUntil;
    if (until != null && until.isAfter(DateTime.now())) {
      return 'AI has used its limit for this minute. Carrying on in ${until.difference(DateTime.now()).inSeconds + 1} s';
    }
    return _working;
  }

  /// Sets the progress line from the counters.
  void _progress() {
    if (!mounted) return;
    final reading = _pagesTotal > 0 && _pagesRead < _pagesTotal;
    final head = reading ? (_pagesTotal == 1 ? 'Reading the page' : 'Reading the pages: $_pagesRead of $_pagesTotal done') : 'Looking for the answers';
    setState(() => _working = _found == 0 ? head : '$head · ${f.count(_found, 'answer')} found');
  }

  bool _loading = false;
  bool _loadAgain = false;

  /// Loads the paper again soon, one load at a time: calls that arrive during a load share the next one.
  Future<void> _reloadSoon() async {
    if (_loading) {
      _loadAgain = true;
      return;
    }
    _loading = true;
    try {
      do {
        _loadAgain = false;
        await _load();
      } while (_loadAgain && mounted);
    } finally {
      _loading = false;
    }
  }

  /// Calls AI through the server, waiting out its per-minute limit. Several calls can wait at once
  /// (the screen counts down the longest wait). Throws when AI fails another way or stays busy too long.
  Future<dynamic> _ai(Future<dynamic> Function() call) async {
    for (var waits = 0;; waits++) {
      try {
        return await call();
      } on ApiException catch (e) {
        if (e.code != 'ai_busy' || waits >= 10 || !mounted) rethrow;
        final secs = (int.tryParse(RegExp(r'(\d+) second').firstMatch(e.message)?.group(1) ?? '') ?? 20).clamp(4, 60);
        final until = DateTime.now().add(Duration(seconds: secs));
        if (_busyUntil == null || until.isAfter(_busyUntil!)) _busyUntil = until;
        while (mounted && DateTime.now().isBefore(until)) {
          setState(() {});
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }
  }

  /// The automatic run: the paper's details, then its pages and their answers. It stops where the
  /// teacher is needed and carries on from there when called again.
  Future<void> _run() async {
    if (_running || _paper == null) return;
    _running = true;
    setState(() => _aiError = null);
    try {
      if (_paper!['ai_details'] == null && _missing.isNotEmpty) {
        try {
          if (mounted) setState(() => _working = 'Working out what this paper is');
          await _ai(() => api.post('/teacher/papers/${widget.id}/detect', null, const Duration(minutes: 2)));
        } on ApiException catch (e) {
          if (mounted) setState(() => _aiError = e.message);
        }
        await _load();
      }
      // The teacher fills in what AI could not find; "Carry on" runs this again.
      if (!mounted || _missing.isNotEmpty) return;
      await _readAndAnswer();
    } finally {
      _running = false;
      _busyUntil = null;
      if (mounted) setState(() => _working = null);
    }
  }

  /// Reads the pages that are not done yet, [_readWidth] at a time, and looks for answers to the
  /// questions already read while the other pages are still being read. A printed answer key on a
  /// late page replaces whatever AI worked out for those questions in the meantime (the server
  /// does that), so the key still wins.
  Future<void> _readAndAnswer() async {
    final todo = [for (final p in _pages) if (p['ai_status'] != 'done') p['page_no'] as int];
    _pagesTotal = todo.length;
    _pagesRead = 0;
    _found = 0;
    _progress();

    var reading = todo.isNotEmpty;
    String? readError;
    final firstRead = Completer<void>();
    final readAll = forEachLimited(todo, _readWidth, (n) async {
      await _ai(() => api.post('/teacher/papers/${widget.id}/pages/$n/read', null, const Duration(minutes: 3)));
      _pagesRead++;
      _progress();
      _reloadSoon();
      if (!firstRead.isCompleted) firstRead.complete();
    }).then<void>((_) {}, onError: (Object e, StackTrace s) {
      if (e is! ApiException) Error.throwWithStackTrace(e, s);
      readError = e.message;
    }).whenComplete(() {
      reading = false;
      if (!firstRead.isCompleted) firstRead.complete();
    });

    // Answers start once the first page is read. Each worker keeps asking while pages are still
    // coming; the server hands every call its own batch, so no question is worked out twice.
    var failed = false;
    String? answerError;
    Future<void> worker() async {
      await firstRead.future;
      while (mounted && !failed) {
        final pagesPending = reading; // was a page still being read when this call went out?
        final dynamic r;
        try {
          r = await _ai(() => api.post('/teacher/papers/${widget.id}/answers', null, const Duration(minutes: 2)));
        } on ApiException catch (e) {
          failed = true;
          answerError = e.message;
          return;
        }
        final tried = r['tried'] as int;
        final fromKey = r['from_key'] as int;
        _found += fromKey + (r['by_ai'] as int);
        _progress();
        if (tried > 0 || fromKey > 0) _reloadSoon();
        if (tried == 0) {
          if (!pagesPending) return; // nothing open, and every page was read before this call
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    }

    await Future.wait([for (var i = 0; i < _answerWidth; i++) worker()]);
    await readAll;
    await _load();
    if (!mounted) return;
    final error = readError ?? answerError;
    if (error != null) setState(() => _aiError = error);
    _summarise();
  }

  /// Says what AI found, counted from the questions as they now are (answers marked in a call
  /// that then had to wait still count).
  void _summarise() {
    final waiting = _drafts.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq').toList();
    final open = waiting.where((d) => d['correct_option'] == null).length;
    final keyed = waiting.where((d) => d['answer_source'] == 'key').length;
    final byAi = waiting.where((d) => d['answer_source'] == 'ai').length;
    final notes = [
      if (keyed > 0) '${f.count(keyed, 'answer')} from the paper\'s answer key',
      if (byAi > 0) '${f.count(byAi, 'answer')} worked out by AI',
    ];
    // Questions AI could not read whole, or that no option fits: the teacher fixes those first.
    final suspect = waiting.where((d) => d['correct_option'] == null && (d['ai_note'] == 'unclear' || d['ai_note'] == 'no_option')).length;
    final repeats = _drafts.where((d) => d['status'] == 'discarded' && d['ai_note'] == 'duplicate').length;
    final more = [
      if (suspect > 0) '${f.count(suspect, 'question')} could not be read whole or may be misprinted: check ${suspect == 1 ? 'it' : 'each'}, then ask for the answer.',
      if (repeats > 0) '${f.count(repeats, 'question')} repeated earlier ones, so AI skipped ${repeats == 1 ? 'it' : 'them'}.',
    ];
    setState(() {
      _answerNote = [
        waiting.isEmpty
            ? 'AI found no multiple-choice questions on these pages.'
            : notes.isEmpty
                ? 'AI was not sure of any answer, so none are marked.${open > 0 ? ' Mark them yourself.' : ''}'
                : '${notes.join(', ')}.${open > 0 ? ' Mark the other $open yourself.' : ''} Check them before saving.',
        ...more,
      ].join(' ');
      _filter = open > 0 ? _Filter.toCheck : _Filter.ready;
    });
  }

  bool _isReady(Map<String, dynamic> d) =>
      d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] != null && (d['needs_diagram'] != true || d['image_key'] != null);

  bool _matches(Map<String, dynamic> d) => switch (_filter) {
        _Filter.toCheck => d['status'] == 'draft' && d['kind'] == 'mcq' && !_isReady(d),
        _Filter.ready => _isReady(d),
        _Filter.byAi => d['status'] == 'draft' && d['answer_source'] == 'ai',
        _Filter.other => d['status'] == 'draft' && d['kind'] == 'other',
        _Filter.saved => d['status'] == 'saved',
        _Filter.skipped => d['status'] == 'discarded',
        _Filter.all => d['status'] != 'discarded',
      };

  Map<String, dynamic> _withChapter(Map<String, dynamic> d) {
    final ch = _chapters.where((c) => c['id'] == d['chapter_id']);
    return {...d, 'chapter': ch.isEmpty ? null : ch.first['name']};
  }

  void _replace(Map<String, dynamic> d) => setState(() => _drafts = [for (final x in _drafts) x['id'] == d['id'] ? d : x]);

  /// Changes a draft; returns it as the server now has it, or null when that failed.
  Future<Map<String, dynamic>?> _patch(Map<String, dynamic> d, Map<String, dynamic> body) async {
    try {
      final r = await api.patch('/teacher/drafts/${d['id']}', body);
      final now = _withChapter(Map<String, dynamic>.from(r['draft']));
      if (mounted) _replace(now);
      return now;
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
      return null;
    }
  }

  /// Marks the right option at once, then tells the server; a failure puts it back.
  Future<void> _mark(Map<String, dynamic> d, int option) async {
    optionTick();
    final id = '${d['id']}';
    final seq = (_markSeq[id] ?? 0) + 1;
    _markSeq[id] = seq;
    final before = d;
    _replace({...d, 'correct_option': option, 'answer_source': 'teacher', 'ai_confidence': null});
    try {
      final r = await api.patch('/teacher/drafts/$id', {'correct_option': option});
      if (mounted && _markSeq[id] == seq) _replace(_withChapter(Map<String, dynamic>.from(r['draft'])));
    } on ApiException catch (e) {
      if (!mounted || _markSeq[id] != seq) return;
      _replace(before);
      showProblem(context, e);
    }
  }

  Future<void> _chooseChapter(Map<String, dynamic> d) async {
    final c = await showChoices<String>(
      context,
      title: 'Chapter',
      subtitle: _chapters.isEmpty ? 'No chapters for this class yet. Add them in Settings.' : null,
      options: [for (final c in _chapters) Choice('${c['id']}', '${c['name']}')],
      selected: d['chapter_id'] as String?,
    );
    if (c?.value != null) _patch(d, {'chapter_id': c!.value});
  }

  Future<void> _addDiagram(Map<String, dynamic> d) async {
    final source = await showCentredCard<ImageSource>(
      context,
      title: 'Add the diagram',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Fig('Photograph or crop just the figure for this question.', style: bodyStyle.copyWith(color: muted)),
        const SizedBox(height: 14),
        SecondaryButton('Take a photo', icon: Ph.camera, onTap: () => Navigator.of(ctx).pop(ImageSource.camera)),
        const SizedBox(height: 10),
        SecondaryButton('Choose from gallery', icon: Ph.images, onTap: () => Navigator.of(ctx).pop(ImageSource.gallery)),
      ]),
    );
    if (source == null || !mounted) return;
    try {
      final up = await pickAndUploadImage(context, source);
      if (up != null) await _patch(d, {'image_key': up.key});
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _edit(Map<String, dynamic> d) async {
    final changed = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => DraftEditor(draft: d)));
    if (changed == null) return;
    final now = await _patch(d, changed);
    // Reworded and still without an answer: AI has another go at it.
    if (now != null && now['kind'] == 'mcq' && now['correct_option'] == null && now['answer_checked'] != true) await _answerAgain();
  }

  /// After the teacher fixes a question, AI looks for its answer once more.
  Future<void> _answerAgain() async {
    if (_running) return;
    _running = true;
    try {
      if (mounted) setState(() => _working = 'Looking for its answer');
      await _ai(() => api.post('/teacher/papers/${widget.id}/answers', null, const Duration(minutes: 2)));
      await _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      _running = false;
      if (mounted) setState(() => _working = null);
    }
  }

  /// The teacher has checked a question AI could not read whole and says it looks right: AI may
  /// now look for its answer.
  Future<void> _confirm(Map<String, dynamic> d) async {
    final now = await _patch(d, {'confirmed': true});
    if (now != null && now['kind'] == 'mcq' && now['correct_option'] == null && now['answer_checked'] != true) await _answerAgain();
  }

  /// Puts a skipped question back among the ones to check.
  Future<void> _restore(Map<String, dynamic> d) => _patch(d, {'status': 'draft'});

  /// For a skipped repeat: which question it repeats, as "Q 4 on page 1".
  String? _repeatOf(Map<String, dynamic> d) {
    final of = _drafts.where((x) => x['id'] == d['duplicate_of']);
    if (of.isEmpty) return null;
    final n = '${of.first['number_label'] ?? ''}'.replaceAll(RegExp(r'[.)\s]+$'), '');
    return '${n.isEmpty ? 'a question' : 'Q $n'} on page ${of.first['page_no']}';
  }

  Future<void> _discard(Map<String, dynamic> d) async {
    final ok = await confirmCard(context, title: 'Skip this question?', body: 'It will be left out of the test.', confirm: 'Skip it', destructive: true);
    if (!ok) return;
    await _patch(d, {'status': 'discarded'});
    await _offerIfDone();
  }

  /// Once a paper is finished (every question saved or skipped) and has no test yet, asks once
  /// whether to publish it.
  bool _offered = false;
  Future<void> _offerIfDone() async {
    final p = _paper;
    if (p == null || _offered || !mounted || _questions.isEmpty || _tests.isNotEmpty) return;
    if (_drafts.any((d) => d['status'] == 'draft' && d['kind'] == 'mcq')) return;
    _offered = true;
    await _offerPublish(p);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final r = await api.post('/teacher/papers/${widget.id}/save');
      final already = r['already_in_bank'] as int? ?? 0;
      _saved = 'Saved ${f.count(r['saved'] as int, 'question')}.'
          '${already > 0 ? ' ${f.count(already, 'question')} ${already == 1 ? 'was' : 'were'} saved before, so ${already == 1 ? 'it was' : 'they were'} skipped.' : ''}';
      _answerNote = null;
      await _load();
      // Everything checked: offer to publish it straight away.
      if (r['still_to_check'] == 0) await _offerIfDone();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editDetails(Map<String, dynamic> p) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _PaperDetails(paper: p),
    ));
    if (changed == true) _load();
  }

  Future<void> _openQuestion(Map<String, dynamic> q) async {
    await context.push('/t/questions/${q['id']}');
    _load();
  }

  /// After the paper is saved: publish its questions as a test now, set the test up first, or not yet.
  Future<void> _offerPublish(Map<String, dynamic> p) async {
    final n = _questions.length;
    final group = paperGroup(p);
    // How many students the group has, so the teacher sees who gets it.
    int? students;
    try {
      final g = await api.get('/teacher/groups');
      students = 0;
      for (final x in (g['groups'] as List)) {
        if (x['class_level'] == p['class_level'] && x['subject_id'] == p['subject_id']) students = x['students'] as int;
      }
    } on ApiException {
      students = null;
    }
    if (!mounted) return;
    final who = students == null ? 'the students in $group' : (students == 1 ? 'the 1 student in $group' : 'the $students students in $group');
    final choice = await showCentredCard<String>(
      context,
      title: 'Publish it as a test?',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Fig(
          'All ${f.count(n, 'question')} go into "${paperName(p)}", with ${_limitFor(n)} minutes to write it. '
          'It goes to $who, who can start as soon as it is published. It closes ${f.when(defaultClosing())}. '
          'Students see their marks after that, or once everyone has finished.',
          style: bodyStyle.copyWith(color: muted),
        ),
        if (students == 0) ...[
          const SizedBox(height: 12),
          InlineNotice('No student is in $group yet, so nobody would see it. Add students to the group first.', icon: Ph.warning),
        ],
        const SizedBox(height: 18),
        PrimaryButton(students == null ? 'Publish now' : 'Publish for all of $group', leadingIcon: Ph.exam, onTap: () => Navigator.of(ctx).pop('publish')),
        const SizedBox(height: 10),
        SecondaryButton('Choose students or settings first', onTap: () => Navigator.of(ctx).pop('edit')),
        const SizedBox(height: 12),
        Center(child: TextAction('Not now', onTap: () => Navigator.of(ctx).pop())),
      ]),
    );
    if (choice != null && mounted) await _makeTest(p, publish: choice == 'publish');
  }

  /// A minute and a half a question, rounded up to a limit the test editor offers.
  int _limitFor(int n) => const [20, 30, 45, 60, 90, 120, 180].firstWhere((m) => m >= (n * 1.5).ceil(), orElse: () => 180);

  /// Every saved question goes into a new test for the paper's class and subject, named after the
  /// paper. Published at once, or left as a draft with the test editor open.
  Future<void> _makeTest(Map<String, dynamic> p, {required bool publish}) async {
    setState(() => _making = true);
    try {
      final closes = defaultClosing();
      final r = await api.post('/teacher/tests', {
        'title': paperName(p),
        'class_level': p['class_level'],
        'subject_id': p['subject_id'],
        'question_ids': [for (final q in _questions) q['id']],
        'time_limit_min': _limitFor(_questions.length),
        'closes_at': closes.toUtc().toIso8601String(),
        'shuffle': true,
        'assign_all': false,
        'assign_group': true,
        'paper_id': p['id'],
      });
      final id = '${r['id']}';
      if (publish) {
        await api.post('/teacher/tests/$id/publish', {'published': true});
        if (!mounted) return;
        // Back to the group, where the test now shows under Live now.
        if (context.canPop()) {
          context.pop();
          return;
        }
        setState(() => _saved = 'Published "${paperName(p)}" for ${paperGroup(p)}. It is open now and closes ${f.when(closes)}.');
        await _load();
      } else {
        if (!mounted) return;
        setState(() => _saved = 'Made the test "${paperName(p)}". It is a draft in ${paperGroup(p)}.');
        await context.push('/t/tests/$id/edit');
        _load();
      }
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _paper;
    if (p == null) {
      return PushedPanel(title: 'Paper', children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    final live = _drafts.where((d) => d['status'] != 'discarded').toList();
    final ready = live.where(_isReady).length;
    final toCheck = live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && !_isReady(d)).length;
    final counts = {
      _Filter.toCheck: toCheck,
      _Filter.ready: ready,
      _Filter.byAi: live.where((d) => d['status'] == 'draft' && d['answer_source'] == 'ai').length,
      _Filter.other: live.where((d) => d['status'] == 'draft' && d['kind'] == 'other').length,
      _Filter.saved: live.where((d) => d['status'] == 'saved').length,
      _Filter.skipped: _drafts.where((d) => d['status'] == 'discarded').length,
      _Filter.all: live.length,
    };
    final unread = _pages.where((x) => x['ai_status'] != 'done').length;

    // Nothing left to read, check or save: the paper is a finished set.
    final asSet = unread == 0 && _working == null && toCheck == 0 && ready == 0 && _questions.isNotEmpty;
    if (asSet && !_review) return _asSet(p);

    return PopScope(
      canPop: !asSet,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _review = false);
      },
      child: _reviewPanel(p, live: live, counts: counts, ready: ready, toCheck: toCheck, unread: unread, asSet: asSet),
    );
  }

  Widget _reviewPanel(Map<String, dynamic> p,
      {required List<Map<String, dynamic>> live,
      required Map<_Filter, int> counts,
      required int ready,
      required int toCheck,
      required int unread,
      required bool asSet}) {
    final shown = (_filter == _Filter.skipped ? _drafts : live).where(_matches).toList();
    final needsDetails = _missing.isNotEmpty;
    final noAnswer = live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null).length;
    final unanswered = live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null && d['answer_checked'] != true).length;
    final named = p['exam_name'] != _unnamed;
    return PushedPanel(
      kicker: 'Question paper · ${paperGroup(p)}',
      title: !named ? (_working != null ? 'Reading' : 'New paper') : paperName(p),
      onBack: asSet ? () => setState(() => _review = false) : null,
      headerTrailing: needsDetails ? null : CircleBtn(icon: Ph.pencilSimple, label: 'Paper details', onTap: () => _editDetails(p)),
      footer: needsDetails
          ? null
          : PrimaryButton(
              _saving ? 'Saving' : (ready == 0 ? 'Save ready questions' : 'Save ${f.count(ready, 'ready question')}'),
              onTap: ready > 0 && !_saving ? _save : null,
              disabledReason: _saving
                  ? null
                  : _working != null
                      ? 'AI is still working'
                      : noAnswer > 0
                          ? '$noAnswer still ${noAnswer == 1 ? 'needs' : 'need'} the right option marked'
                          : toCheck > 0
                              ? '$toCheck still ${toCheck == 1 ? 'needs its' : 'need their'} diagram'
                              : (live.isEmpty ? 'Nothing to save yet' : 'Everything here is saved or skipped'),
            ),
      children: [
        const SizedBox(height: 8),
        if (!needsDetails)
          _DetailsLine(
            text: [
              f.count(live.length, 'question'),
              p['category'] ?? 'No category',
              if (p['chapter'] != null) '${p['chapter']}',
            ].join(' · '),
            byAi: p['ai_details'] != null,
            onEdit: () => _editDetails(p),
          ),
        const SizedBox(height: 14),
        SizedBox(
          height: 84,
          child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [
            for (final (i, pg) in _pages.indexed) ...[
              if (i > 0) const SizedBox(width: 10),
              Pressable(
                label: 'Open page ${pg['page_no']}',
                onTap: pg['image_url'] == null
                    ? null
                    : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PageView(url: '${pg['image_url']}', n: pg['page_no'] as int))),
                child: Stack(children: [
                  Container(
                    width: 63,
                    height: 84,
                    decoration: surface(radius: 10, shadow: e1),
                    clipBehavior: Clip.antiAlias,
                    child: pg['image_url'] == null ? null : Image.network('${pg['image_url']}', fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                  ),
                  Positioned(right: 5, bottom: 5, child: TagChip('${pg['page_no']}')),
                ]),
              ),
            ],
          ]),
        ),
        const SizedBox(height: 18),
        if (_working != null)
          InlineNotice('$_workingText. This takes a few seconds.', tone: Tone.ai, icon: Ph.scan)
        else if (needsDetails) ...[
          if (_aiError != null) ...[InlineNotice(_aiError!, tone: Tone.danger, icon: Ph.warning), const SizedBox(height: 12)],
          _MissingDetails(
            onSave: (body) async {
              await api.patch('/teacher/papers/${widget.id}', body);
              await _load();
              _run();
            },
          ),
        ] else if (_aiError != null)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InlineNotice(_aiError!, tone: Tone.danger, icon: Ph.warning),
            const SizedBox(height: 10),
            SecondaryButton('Try again', icon: Ph.arrowsClockwise, onTap: _run),
          ])
        else if (unread > 0)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InlineNotice('${f.count(unread, 'page')} not read yet.', tone: Tone.ai, icon: Ph.scan),
            const SizedBox(height: 10),
            SecondaryButton('Read with AI', icon: Ph.scan, tint: aiAccentInk, onTap: _run),
          ])
        else if (unanswered > 0)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InlineNotice('AI has not looked for ${f.count(unanswered, 'answer')} yet.', tone: Tone.ai, icon: Ph.scan),
            const SizedBox(height: 10),
            SecondaryButton('Find answers with AI', icon: Ph.scan, tint: aiAccentInk, onTap: _run),
          ])
        else
          InlineNotice(_answerNote ?? 'Read by AI. Check each question and its answer before saving.', tone: Tone.ai, icon: Ph.scan),
        if (_saved != null) ...[
          const SizedBox(height: 10),
          InlineNotice(_saved!, tone: Tone.success, icon: Ph.checkCircle),
        ],
        if (!needsDetails) ...[
          const SizedBox(height: 16),
          FilterBar(padding: EdgeInsets.zero, children: [
            SelectPill(
              label: _filterLabels[_filter]!,
              count: counts[_filter],
              active: _filter != _Filter.all,
              onTap: () async {
                final c = await showChoices<_Filter>(
                  context,
                  title: 'Show',
                  options: [for (final x in _Filter.values) Choice(x, _filterLabels[x]!, count: counts[x])],
                  selected: _filter,
                );
                if (c?.value != null) setState(() => _filter = c!.value!);
              },
            ),
          ]),
          const SizedBox(height: 14),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                switch (_filter) {
                  _Filter.toCheck => live.isEmpty ? 'Questions appear here once AI has read the pages.' : 'Nothing left to check.',
                  _Filter.ready => 'Questions with their answer marked appear here.',
                  _Filter.byAi => 'No answers from AI here.',
                  _Filter.other => 'No written-answer questions on this paper.',
                  _Filter.saved => 'Nothing saved yet.',
                  _Filter.skipped => 'No skipped questions.',
                  _Filter.all => 'No questions yet.',
                },
                style: bodyStyle.copyWith(color: muted),
              ),
            ),
          for (final (i, d) in shown.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            _DraftCard(
              d: d,
              ready: _isReady(d),
              onMark: d['status'] == 'draft' ? (o) => _mark(d, o) : null,
              onChapter: d['status'] == 'draft' ? () => _chooseChapter(d) : null,
              onEdit: d['status'] == 'draft' ? () => _edit(d) : null,
              onDiagram: d['status'] == 'draft' ? () => _addDiagram(d) : null,
              onDiscard: d['status'] == 'draft' ? () => _discard(d) : null,
              onRestore: d['status'] == 'discarded' ? () => _restore(d) : null,
              onConfirm: d['status'] == 'draft' && d['ai_note'] == 'unclear' ? () => _confirm(d) : null,
              repeatOf: _repeatOf(d),
            ),
          ],
        ],
      ],
    );
  }

  /// The paper as a named set of questions, ready to be published as a test.
  Widget _asSet(Map<String, dynamic> p) {
    final n = _questions.length;
    final group = paperGroup(p);
    return PushedPanel(
      kicker: 'Question paper · $group',
      title: paperName(p),
      headerTrailing: CircleBtn(icon: Ph.pencilSimple, label: 'Paper details', onTap: () => _editDetails(p)),
      footer: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_tests.isEmpty)
          PrimaryButton(_making ? 'Making the test' : 'Publish as a test', leadingIcon: Ph.exam, onTap: _making ? null : () => _offerPublish(p))
        else
          SecondaryButton(_making ? 'Making the test' : 'Make another test from it', icon: Ph.exam, onTap: _making ? null : () => _offerPublish(p)),
        const SizedBox(height: 8),
        Fig('All ${f.count(n, 'question')} go into a test for $group.', style: labelStyle, textAlign: TextAlign.center),
      ]),
      children: [
        const SizedBox(height: 8),
        _DetailsLine(
          text: [f.count(n, 'question'), p['category'] ?? 'No category', if (p['chapter'] != null) '${p['chapter']}'].join(' · '),
          byAi: p['ai_details'] != null,
          onEdit: () => _editDetails(p),
        ),
        if (_saved != null) ...[
          const SizedBox(height: 14),
          InlineNotice(_saved!, tone: Tone.success, icon: Ph.checkCircle),
        ],
        if (_tests.isNotEmpty) ...[
          SectionRule('Tests from this paper', count: _tests.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
          for (final (i, t) in _tests.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              leading: Icon(Ph.exam, size: 20, color: t['status'] == 'published' ? success : faint),
              title: '${t['title']}',
              meta: '${t['status'] == 'published' ? 'Published' : 'Draft, not published'} · ${f.count(t['question_count'] as int, 'question')}',
              chevron: true,
              onTap: () async {
                await context.push(t['status'] == 'published' ? '/t/tests/${t['id']}' : '/t/tests/${t['id']}/edit');
                _load();
              },
            ),
          ],
        ],
        SectionRule('Questions', count: n, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        for (final (i, q) in _questions.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          _SetRow(n: i + 1, q: q, onTap: () => _openQuestion(q)),
        ],
        const SizedBox(height: 8),
        Center(
          child: TextAction('See the AI drafts, page by page', onTap: () {
            setState(() {
              _review = true;
              _filter = _Filter.all;
            });
          }),
        ),
      ],
    );
  }
}

/// A paper's details in one line, with a plain Edit button: what AI wrote is never final.
class _DetailsLine extends StatelessWidget {
  const _DetailsLine({required this.text, required this.byAi, required this.onEdit});
  final String text;
  final bool byAi;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Row(children: [
        if (byAi) ...[const TagChip('Found by AI', tone: Tone.ai), const SizedBox(width: 8)],
        Expanded(child: Fig(text, style: labelStyle, maxLines: 2)),
        const SizedBox(width: 10),
        Pressable(
          label: 'Edit the paper details',
          onTap: onEdit,
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 13),
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rPill)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Ph.pencilSimple, size: 15, color: ink),
              const SizedBox(width: 6),
              Text('Edit details', style: chipStyle.copyWith(color: ink)),
            ]),
          ),
        ),
      ]);
}

/// A paper's name, when AI could not find one: the teacher types it before AI carries on.
class _MissingDetails extends StatefulWidget {
  const _MissingDetails({required this.onSave});
  final Future<void> Function(Map<String, dynamic> body) onSave;

  @override
  State<_MissingDetails> createState() => _MissingDetailsState();
}

class _MissingDetailsState extends State<_MissingDetails> {
  final _name = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? get _gap => _name.text.trim().isEmpty ? 'Name the paper, e.g. Half-yearly exam.' : null;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.onSave({'exam_name': _name.text.trim()});
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gap = _gap;
    return Surface(
      shadow: e2,
      padding: const EdgeInsets.fromLTRB(17, 16, 17, 17),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Name this paper', style: cardTitleStyle),
        const SizedBox(height: 6),
        Fig('AI could not make out the name of the paper. Type one and it reads the questions.', style: bodyStyle.copyWith(color: muted)),
        const FormLabel('Name', top: 18),
        GroupedInputs(children: [
          BareField(controller: _name, placeholder: 'e.g. Half-yearly exam', capitalization: TextCapitalization.sentences),
        ]),
        const SizedBox(height: 18),
        PrimaryButton(_busy ? 'Saving' : 'Carry on', onTap: gap == null && !_busy ? _save : null, disabledReason: _busy ? null : gap),
      ]),
    );
  }
}

/// A question in a paper's set: its place in the paper, the question, and its chapter.
class _SetRow extends StatelessWidget {
  const _SetRow({required this.n, required this.q, required this.onTap});
  final int n;
  final Map<String, dynamic> q;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(17, 15, 15, 15),
          decoration: surface(radius: rCard, shadow: e1),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 22,
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('$n', style: numStyle(size: 12, weight: FontWeight.w600, color: faint)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MathText('${q['text']}', style: rowTitleStyle, maxLines: 3),
                if (q['chapter'] != null) ...[
                  const SizedBox(height: 2),
                  Fig('${q['chapter']}', style: labelStyle.copyWith(color: muted), maxLines: 1),
                ],
              ]),
            ),
          ]),
        ),
      );
}

/// A paper's name, and a way to delete it. The class and subject are the group's, so they stay as they are.
class _PaperDetails extends StatefulWidget {
  const _PaperDetails({required this.paper});
  final Map<String, dynamic> paper;

  @override
  State<_PaperDetails> createState() => _PaperDetailsState();
}

class _PaperDetailsState extends State<_PaperDetails> {
  late final _name = TextEditingController(text: widget.paper['exam_name'] == _unnamed ? '' : '${widget.paper['exam_name']}');
  bool _busy = false;

  /// Deletes the paper, its pages and the questions saved from it that no test uses.
  Future<void> _delete() async {
    final ok = await confirmCard(
      context,
      title: 'Delete this paper?',
      body: 'Its pages go, and so do the questions saved from it, except any that a test uses.',
      confirm: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await api.delete('/teacher/papers/${widget.paper['id']}');
      if (mounted) context.go('/t');
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? get _gap => _name.text.trim().isEmpty ? 'Name the paper, e.g. Half-yearly exam.' : null;

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await api.patch('/teacher/papers/${widget.paper['id']}', {'exam_name': _name.text.trim()});
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gap = _gap;
    return PushedPanel(
      kicker: 'Question paper · ${paperGroup(widget.paper)}',
      title: 'Paper details',
      footer: PrimaryButton(_busy ? 'Saving' : 'Save', onTap: gap == null && !_busy ? _save : null, disabledReason: _busy ? null : gap),
      children: [
        const FormLabel('Name'),
        GroupedInputs(children: [
          BareField(controller: _name, placeholder: 'Paper name, e.g. Half-yearly exam', capitalization: TextCapitalization.sentences),
        ]),
        const SizedBox(height: 30),
        Center(child: TextAction('Delete this paper', color: danger, onTap: _delete)),
      ],
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.d,
    required this.ready,
    this.onMark,
    this.onChapter,
    this.onEdit,
    this.onDiagram,
    this.onDiscard,
    this.onRestore,
    this.onConfirm,
    this.repeatOf,
  });
  final Map<String, dynamic> d;
  final bool ready;
  final ValueChanged<int>? onMark;
  final VoidCallback? onChapter;
  final VoidCallback? onEdit;
  final VoidCallback? onDiagram;
  final VoidCallback? onDiscard;
  final VoidCallback? onRestore;

  /// For a question AI could not read whole: the teacher says it looks right, and AI answers it.
  final VoidCallback? onConfirm;

  /// For a skipped repeat, the question it repeats ("Q 4 on page 1").
  final String? repeatOf;

  /// What AI noticed about this question, and whether the teacher needs to act on it.
  (String, bool)? get _note => switch (d['ai_note']) {
        'unclear' => ('Part of this could not be read on the page, so AI did not answer it. Check the question, then ask for the answer.', true),
        'no_option' => ('Neither AI model found an option that fits, so it may be misprinted. Check it against the paper.', true),
        'duplicate' => ('Same as ${repeatOf ?? 'an earlier question'}, so it was skipped.', false),
        'in_bank' => ('You already have this question, so it was not saved again.', false),
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final options = (d['options'] as List?)?.cast<String>() ?? const [];
    final correct = d['correct_option'] as int?;
    final saved = d['status'] == 'saved';
    final skipped = d['status'] == 'discarded';
    final mcq = d['kind'] == 'mcq';
    final note = saved ? null : _note;
    final needsDiagram = d['needs_diagram'] == true && d['image_key'] == null;
    final number = '${d['number_label'] ?? ''}'.replaceAll(RegExp(r'[.)\s]+$'), '');
    final label = number.isEmpty ? 'Q' : 'Q $number';
    final source = d['answer_source'] as String?;
    final sure = d['ai_confidence'] is num ? ((d['ai_confidence'] as num) * 100).round() : null;
    return Surface(
      padding: const EdgeInsets.fromLTRB(17, 14, 17, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Kicker('$label · page ${d['page_no']}'),
          const SizedBox(width: 8),
          if (!saved && !ready && !skipped) const TagChip('AI draft', tone: Tone.ai),
          const Spacer(),
          if (skipped)
            const TagChip('Skipped')
          else if (saved)
            const TagChip('Saved', tone: Tone.success)
          else if (!mcq)
            const TagChip('Not multiple choice')
          else if (correct == null)
            const TagChip('Mark the answer', tone: Tone.warning)
          else if (needsDiagram)
            const TagChip('Needs a diagram', tone: Tone.warning)
          else
            const TagChip('Ready', tone: Tone.success),
        ]),
        const SizedBox(height: 10),
        MathText('${d['text']}', style: optionStyle.copyWith(fontWeight: FontWeight.w600, fontSize: 15)),
        if (d['image_url'] != null) ...[
          const SizedBox(height: 10),
          ClipRRect(borderRadius: BorderRadius.circular(rSmall), child: Image.network('${d['image_url']}', height: 140, errorBuilder: (_, _, _) => const SizedBox())),
        ],
        if (mcq) ...[
          const SizedBox(height: 6),
          for (final (i, o) in options.indexed)
            Pressable(
              onTap: onMark == null ? null : () => onMark!(i),
              label: 'Mark option ${'ABCD'[i]} as right${correct == i ? ', marked' : ''}',
              child: AnimatedContainer( // motion: approved
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                decoration: BoxDecoration(
                  color: correct == i ? successSoft : successSoft.withValues(alpha: 0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(children: [
                  OptionMark(selected: correct == i, size: 22, color: success, onColor: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MathText(o,
                        style: bodyStyle.copyWith(fontSize: 14.5, color: correct == i ? ink : body, fontWeight: correct == i ? FontWeight.w600 : FontWeight.w500)),
                  ),
                ]),
              ),
            ),
          if (correct != null && !saved && (source == 'key' || source == 'ai'))
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 0, 0),
              child: Row(children: [
                Icon(Ph.scan, size: 14, color: aiAccentInk),
                const SizedBox(width: 6),
                Expanded(
                  child: Fig(
                    source == 'key' ? 'From the paper\'s own answer key' : 'Worked out by AI${sure == null ? '' : ', $sure% sure'}. Check it.',
                    style: labelStyle.copyWith(color: aiAccentInk),
                  ),
                ),
              ]),
            ),
        ],
        if (note != null)
          Padding(
            padding: EdgeInsets.fromLTRB(mcq ? 10 : 0, 8, 0, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(note.$2 ? Ph.warning : Ph.copy, size: 14, color: note.$2 ? warning : muted),
              ),
              const SizedBox(width: 6),
              Expanded(child: Fig(note.$1, style: labelStyle.copyWith(color: note.$2 ? warning : muted))),
            ]),
          ),
        if (note != null && onConfirm != null && correct == null)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(left: mcq ? 6 : 0),
              child: TextAction('Looks right, find the answer', color: aiAccentInk, onTap: onConfirm),
            ),
          ),
        const SizedBox(height: 8),
        Container(height: 1, color: hairline),
        const SizedBox(height: 10),
        // The chapter takes what room is left and shortens itself, so a long chapter name never
        // pushes the edit and skip buttons off the card.
        Row(children: [
          Expanded(
            child: Row(children: [
              // A question with no chapter shows nothing: chapters are optional and no longer asked for.
              if (d['chapter'] != null)
                Flexible(
                  child: Pressable(
                    onTap: onChapter,
                    label: 'Change chapter',
                    child: TagChip('${d['chapter']}'),
                  ),
                ),
              if (d['chapter'] != null && d['ai_chapter_guess'] != null && !saved) ...[
                const SizedBox(width: 8),
                Text('guessed by AI', style: labelStyle.copyWith(color: faint), maxLines: 1),
              ],
            ]),
          ),
          if (onDiagram != null && needsDiagram) ...[const SizedBox(width: 8), TextAction('Add diagram', color: warning, onTap: onDiagram)],
          if (onEdit != null) ...[
            const SizedBox(width: 8),
            CircleBtn(icon: Ph.pencilSimple, size: 34, ground: fill, label: 'Edit question', onTap: onEdit),
          ],
          if (onDiscard != null) ...[
            const SizedBox(width: 8),
            CircleBtn(icon: Ph.trash, size: 34, ground: fill, tint: muted, label: 'Skip question', onTap: onDiscard),
          ],
          if (onRestore != null) ...[const SizedBox(width: 8), TextAction('Bring back', color: ink, onTap: onRestore)],
        ]),
      ]),
    );
  }
}

class _PageView extends StatelessWidget {
  const _PageView({required this.url, required this.n});
  final String url;
  final int n;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
              child: Row(children: [
                CircleBtn(icon: Ph.arrowLeft, label: 'Back', onTap: () => Navigator.of(context).pop()),
                const SizedBox(width: 14),
                Fig('Page $n', style: sectionStyle),
              ]),
            ),
            Expanded(child: InteractiveViewer(maxScale: 5, child: Center(child: Image.network(url)))),
          ]),
        ),
      );
}

/// Fix the AI's transcription: text, options, or whether it is multiple choice at all.
class DraftEditor extends StatefulWidget {
  const DraftEditor({super.key, required this.draft});
  final Map<String, dynamic> draft;

  @override
  State<DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<DraftEditor> {
  late final _text = TextEditingController(text: '${widget.draft['text']}');
  late final _options = List.generate(4, (i) {
    final o = (widget.draft['options'] as List?)?.cast<String>() ?? const [];
    return TextEditingController(text: i < o.length ? o[i] : '');
  });
  late bool _mcq = widget.draft['kind'] == 'mcq';
  final _focus = List.generate(5, (_) => FocusNode());
  int _last = 0;

  @override
  void initState() {
    super.initState();
    for (final (i, f) in _focus.indexed) {
      f.addListener(() {
        if (f.hasFocus) _last = i;
      });
    }
    for (final c in [_text, ..._options]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in [_text, ..._options]) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  String? get _missing {
    if (_text.text.trim().isEmpty) return 'The question cannot be empty.';
    if (_mcq && _options.any((o) => o.text.trim().isEmpty)) return 'Fill in all four options.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final missing = _missing;
    return PushedPanel(
      kicker: 'AI draft',
      title: 'Fix question',
      footer: PrimaryButton(
        'Done',
        onTap: missing == null
            ? () => Navigator.of(context).pop({
                  'text': _text.text.trim(),
                  'kind': _mcq ? 'mcq' : 'other',
                  'options': _mcq ? [for (final o in _options) o.text.trim()] : <String>[],
                })
            : null,
        disabledReason: missing,
      ),
      children: [
        const FormLabel('Type'),
        ChipRow(padding: EdgeInsets.zero, children: [
          SegChip('Multiple choice', selected: _mcq, onTap: () => setState(() => _mcq = true)),
          SegChip('Not multiple choice', selected: !_mcq, onTap: () => setState(() => _mcq = false)),
        ]),
        const FormLabel('Question'),
        GroupedInputs(children: [
          BareField(controller: _text, focusNode: _focus[0], placeholder: 'Question', maxLines: null, minLines: 2, capitalization: TextCapitalization.sentences),
        ]),
        const SizedBox(height: 10),
        MathToolbar(onInsert: (s) {
          insertInto([_text, ..._options][_last], s);
          _focus[_last].requestFocus();
        }),
        if (_mcq) ...[
          const FormLabel('Options'),
          GroupedInputs(children: [
            for (var i = 0; i < 4; i++) BareField(controller: _options[i], focusNode: _focus[i + 1], placeholder: 'Option ${'ABCD'[i]}'),
          ]),
        ],
        const FormLabel('Preview'),
        Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MathText(_text.text, style: optionStyle),
            if (_mcq)
              for (var i = 0; i < 4; i++)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 22, child: Text('ABCD'[i], style: tagStyle.copyWith(fontSize: 12, color: muted))),
                    Expanded(child: MathText(_options[i].text.isEmpty ? '-' : _options[i].text, style: bodyStyle.copyWith(color: ink))),
                  ]),
                ),
          ]),
        ),
      ],
    );
  }
}
