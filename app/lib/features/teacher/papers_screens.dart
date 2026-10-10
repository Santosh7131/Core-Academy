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
import 'questions_screens.dart' show MathToolbar, insertInto, pickAndUploadImage;
import '../../core/levels.dart';

/// A paper's name, as AI found it or the teacher typed it.
String paperName(Map<String, dynamic> p) => '${p['exam_name']}';

/// "10th Science", or what is still unknown about a paper.
String paperGroup(Map<String, dynamic> p) {
  final cls = p['class_level'] as int?;
  if (cls == null) return 'Class not set';
  return p['subject'] == null ? className(cls) : groupName(cls, '${p['subject']}');
}

/// The name a paper has before AI or the teacher names it (the API's placeholder).
const _unnamed = 'New paper';


// ---------------------------------------------------------------- upload

/// Pages first: AI works out the rest once they are uploaded.
class UploadPaperScreen extends StatefulWidget {
  /// From a group's page: the paper's class and subject are the group's.
  const UploadPaperScreen({super.key, this.classLevel, this.subjectId, this.subjectName});
  final int? classLevel;
  final String? subjectId;
  final String? subjectName;

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
        // Each page's size, so storage takes exactly that many bytes for it.
        'sizes': [for (final p in _pages) p.length],
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
    final locked = _busy || _pages.length >= 20;
    final subject = widget.subjectName;
    return PushedPanel(
      kicker: widget.classLevel != null && subject != null && subject.isNotEmpty ? groupName(widget.classLevel!, subject) : 'Question paper',
      title: 'Add the paper',
      footer: PrimaryButton(
        _status ?? (_pages.isEmpty ? 'Read with AI' : 'Read ${f.count(_pages.length, 'page')} with AI'),
        leadingIcon: Ph.scan,
        busy: _busy,
        onTap: _pages.isNotEmpty && !_busy ? _upload : null,
        disabledReason: _busy ? null : (_pages.isEmpty ? 'Add at least one page.' : null),
      ),
      children: [
        const SizedBox(height: 14),
        Fig('Include the answer key if the paper has one.', style: bodyStyle.copyWith(color: muted)),
        const SizedBox(height: 20),
        Surface(
          child: Column(children: [
            _SourceRow(icon: Ph.camera, title: 'Take photos', caption: 'One for each page, in good light', onTap: locked ? null : _camera),
            _SourceRow(icon: Ph.images, title: 'Choose from the gallery', caption: 'Photos you already took', onTap: locked ? null : _gallery),
            _SourceRow(icon: Ph.filePdf, title: 'Pick a PDF', caption: 'Up to 20 pages', onTap: locked ? null : _pdf, last: true),
          ]),
        ),
        if (_pages.isNotEmpty) ...[
          SectionRule('Pages', count: _pages.length, padding: const EdgeInsets.fromLTRB(0, 28, 0, 14)),
          Wrap(spacing: 12, runSpacing: 14, children: [
            for (final (i, b) in _pages.indexed)
              Reveal(
                dy: 8,
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    width: 72,
                    height: 96,
                    decoration: surface(radius: 12, shadow: e1),
                    clipBehavior: Clip.antiAlias,
                    child: Image.memory(b, fit: BoxFit.cover),
                  ),
                  Positioned(left: 6, bottom: 6, child: TagChip('${i + 1}')),
                  Positioned(
                    right: -8,
                    top: -8,
                    child: CircleBtn(icon: Ph.x, size: 28, label: 'Remove page ${i + 1}', filled: true, onTap: _busy ? null : () => setState(() => _pages.removeAt(i))),
                  ),
                ]),
              ),
          ]),
        ],
      ],
    );
  }
}

/// One way of adding pages: its icon, what it does, a caret.
class _SourceRow extends StatelessWidget {
  const _SourceRow({required this.icon, required this.title, required this.caption, required this.onTap, this.last = false});
  final IconData icon;
  final String title;
  final String caption;
  final VoidCallback? onTap;
  final bool last;

  @override
  Widget build(BuildContext context) => Pressable(
        label: title,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(17, 14, 15, 14),
          decoration: last ? null : BoxDecoration(border: Border(bottom: BorderSide(color: hairline))),
          child: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(13)),
              child: Icon(icon, size: 21, color: onTap == null ? faint : ink),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: rowTitleStyle.copyWith(color: onTap == null ? muted : ink)),
                const SizedBox(height: 2),
                Fig(caption, style: labelStyle),
              ]),
            ),
            Icon(Ph.caretRight, size: 16, color: faint),
          ]),
        ),
      );
}

// ---------------------------------------------------------------- review

enum _Filter { toCheck, ready, other, saved, skipped }

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

class _PaperReviewScreenState extends State<PaperReviewScreen> with WidgetsBindingObserver {
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
  bool _bulk = false;
  final Set<String> _openRows = {};
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
    WidgetsBinding.instance.addObserver(this);
    // A paper opened with work left (a page not read, a question nobody has looked at: the screen was closed or
    // the phone was busy last time) carries on by itself.
    _load().then((_) {
      if (widget.autoRead || _workLeft) _run();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from another app or a locked screen: look at the paper again, and finish what was interrupted.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _running) return;
    _load().then((_) {
      if (mounted && _workLeft && !_running) _run();
    });
  }

  /// Pages AI has not read, questions it has not looked for an answer to, or questions waiting for a second opinion.
  bool get _workLeft =>
      _pages.any((p) => p['ai_status'] != 'done' && p['uploaded'] != false) ||
      _drafts.any((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null && d['answer_checked'] != true && d['needs_diagram'] != true) ||
      _secondPending > 0;

  /// Questions the first two AI checks could not settle, which a stronger model is asked about next.
  int get _secondPending => _drafts.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null && d['ai_votes'] != null).length;

  /// The stronger model is being asked right now; the review can be used meanwhile.
  bool _asking = false;

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

  /// How many second-opinion calls run at once: the stronger models are slow and have small limits.
  static const _secondWidth = 2;

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
    _bulk = true;
    setState(() => _aiError = null);
    try {
      // The paper's title is asked for alongside the reading and never waited for: a paper that AI could not name
      // keeps the date it was made, and the pages are read all the same.
      final named = _paper!['ai_details'] == null
          ? _ai(() => api.post('/teacher/papers/${widget.id}/detect', null, const Duration(minutes: 2))).then<void>((_) {}, onError: (_) {})
          : Future<void>.value();
      if (!mounted || _missing.isNotEmpty) return;
      await _readAndAnswer();
      await named;
      await _load();
      // The paper is ready to review now. Questions the first two checks could not settle get a second
      // opinion from a stronger model while the tutor reads on.
      _bulk = false;
      if (mounted) setState(() => _working = null);
      await _secondOpinions();
    } finally {
      _running = false;
      _bulk = false;
      _busyUntil = null;
      if (mounted) setState(() => _working = null);
    }
  }

  /// Asks a stronger AI model about the questions the first two checks could not settle. It is slow and often
  /// busy, so it runs after the review is on screen and never shows an error: whatever it cannot settle stays
  /// with the tutor, with what each check chose on the card (the server gives up on a question after two tries).
  Future<void> _secondOpinions() async {
    if (!mounted || _secondPending == 0) return;
    setState(() => _asking = true);
    try {
      var stuck = false;
      Future<void> worker() async {
        while (mounted && !stuck) {
          final dynamic r;
          try {
            r = await api.post('/teacher/papers/${widget.id}/second-opinion', null, const Duration(minutes: 2));
          } on ApiException {
            stuck = true;
            return;
          }
          if ((r['tried'] as int) == 0) return;
          _reloadSoon();
          // Nobody could be asked, so the strong models are busy: a pause before the next try helps.
          if ((r['asked'] ?? 1) == 0) await Future<void>.delayed(const Duration(seconds: 8));
        }
      }

      await Future.wait([for (var i = 0; i < _secondWidth; i++) worker()]);
      await _load();
    } finally {
      if (mounted) setState(() => _asking = false);
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
    final firstRead = Completer<void>();
    // One page that cannot be read does not stop the others. A page that fails is tried once more after a
    // short pause, since a busy model or a bad moment on the line is usually over by then.
    late final Map<int, Object> unread;
    final readAll = forEachSettled(todo, _readWidth, (n) async {
      for (var attempt = 0;; attempt++) {
        try {
          await _ai(() => api.post('/teacher/papers/${widget.id}/pages/$n/read', null, const Duration(minutes: 3)));
          break;
        } on ApiException {
          if (attempt >= 1 || !mounted) rethrow;
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      _pagesRead++;
      _progress();
      _reloadSoon();
      if (!firstRead.isCompleted) firstRead.complete();
    }).then<void>((failed) => unread = failed).whenComplete(() {
      reading = false;
      if (!firstRead.isCompleted) firstRead.complete();
    });

    // Answers start once the first page is read. Each worker keeps asking while pages are still
    // coming; the server hands every call its own batch, so no question is worked out twice.
    var failed = false;
    String? answerError;
    Future<void> worker() async {
      await firstRead.future;
      var hiccups = 0;
      while (mounted && !failed) {
        final pagesPending = reading; // was a page still being read when this call went out?
        final dynamic r;
        try {
          r = await _ai(() => api.post('/teacher/papers/${widget.id}/answers', null, const Duration(minutes: 2)));
        } on ApiException catch (e) {
          // A slow reply, a server blip or a dropped connection: wait a moment and ask again before giving up.
          if ((e.status == 0 || e.status >= 500) && ++hiccups <= 3) {
            await Future<void>.delayed(Duration(seconds: 3 * hiccups));
            continue;
          }
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
    final why = unread.values.whereType<ApiException>().map((e) => e.message).firstOrNull ?? 'Try again in a moment.';
    final error = answerError ??
        (unread.isEmpty
            ? null
            : unread.length == 1
                ? 'Page ${unread.keys.first} could not be read. $why'
                : '${unread.length} pages could not be read. $why');
    if (error != null) setState(() => _aiError = error);
    _summarise();
  }

  /// Points the list at what needs the tutor first, or at the ready questions when nothing does.
  void _summarise() {
    final open = _drafts.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null).length;
    setState(() => _filter = open > 0 ? _Filter.toCheck : _Filter.ready);
  }

  bool _isReady(Map<String, dynamic> d) =>
      d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] != null && (d['needs_diagram'] != true || d['image_key'] != null);

  bool _matches(Map<String, dynamic> d) => switch (_filter) {
        _Filter.toCheck => d['status'] == 'draft' && d['kind'] == 'mcq' && !_isReady(d),
        _Filter.ready => _isReady(d),
        _Filter.other => d['status'] == 'draft' && d['kind'] == 'other',
        _Filter.saved => d['status'] == 'saved',
        _Filter.skipped => d['status'] == 'discarded',
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
      if (mounted) setState(() => _working = null);
      await _secondOpinions();
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
        Fig('${f.count(n, 'question')} · ${_limitFor(n)} min · closes ${f.when(defaultClosing())}', style: labelStyle.copyWith(fontSize: 12.5), numColor: ink),
        const SizedBox(height: 10),
        Fig('Goes to $who. Students see their marks after it closes, or once everyone has finished.', style: bodyStyle.copyWith(color: muted)),
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
      _Filter.other: live.where((d) => d['status'] == 'draft' && d['kind'] == 'other').length,
      _Filter.saved: live.where((d) => d['status'] == 'saved').length,
      _Filter.skipped: _drafts.where((d) => d['status'] == 'discarded').length,
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

  /// How far AI has got, for the reader card: pages first, then the answers.
  ({int done, int total, String unit, String line}) _readerFacts(List<Map<String, dynamic>> live) {
    final pages = _pages.length;
    final pagesDone = _pages.where((x) => x['ai_status'] == 'done').length;
    final mcq = live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq').toList();
    if (pagesDone < pages) {
      final marked = mcq.where((d) => d['correct_option'] != null).length;
      return (
        done: pagesDone,
        total: pages,
        unit: pages == 1 ? 'page read' : 'pages read',
        line: mcq.isEmpty ? 'Reading the first page.' : '${f.count(mcq.length, 'question')} found so far, ${f.count(marked, 'answer')} worked out.',
      );
    }
    final toAnswer = mcq.where((d) => d['needs_diagram'] != true).toList();
    final answered = toAnswer.where((d) => d['correct_option'] != null || d['answer_checked'] == true).length;
    return (done: answered, total: toAnswer.length, unit: 'answers worked out', line: '${f.count(mcq.length, 'question')} found.');
  }

  Widget _reviewPanel(Map<String, dynamic> p,
      {required List<Map<String, dynamic>> live,
      required Map<_Filter, int> counts,
      required int ready,
      required int toCheck,
      required int unread,
      required bool asSet}) {
    final needsDetails = _missing.isNotEmpty;
    final reading = _working != null && _bulk;
    final shown = (_filter == _Filter.skipped ? _drafts : live).where(_matches).toList();
    final noAnswer = live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null).length;
    final unanswered = live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null && d['answer_checked'] != true).length;
    final named = p['exam_name'] != _unnamed;
    // Questions still needing the tutor, page by page: the badges on the page strip.
    final issues = <int, int>{};
    for (final d in live) {
      if (d['status'] == 'draft' && d['kind'] == 'mcq' && !_isReady(d)) {
        final n = d['page_no'] as int;
        issues[n] = (issues[n] ?? 0) + 1;
      }
    }
    final tabs = [
      (_Filter.toCheck, 'Needs you'),
      (_Filter.ready, 'Ready'),
      (_Filter.skipped, 'Skipped'),
      if ((counts[_Filter.saved] ?? 0) > 0) (_Filter.saved, 'Saved'),
      if ((counts[_Filter.other] ?? 0) > 0) (_Filter.other, 'Other'),
    ];

    Widget card(Map<String, dynamic> d) => _DraftCard(
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
        );

    final facts = reading ? _readerFacts(live) : null;
    return PushedPanel(
      onRefresh: reading ? null : _load,
      kicker: 'Question paper · ${paperGroup(p)}',
      title: !named ? (_working != null ? 'Reading' : 'New paper') : paperName(p),
      onBack: asSet ? () => setState(() => _review = false) : null,
      headerTrailing: needsDetails ? null : CircleBtn(icon: Ph.pencilSimple, label: 'Paper details', onTap: () => _editDetails(p)),
      footer: needsDetails || reading
          ? null
          : PrimaryButton(
              _saving ? 'Saving' : (ready == 0 ? 'Save ready questions' : 'Save ${f.count(ready, 'ready question')}'),
              busy: _saving,
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
        const SizedBox(height: 22),
        if (facts != null) ...[
          Reveal(scope: this, id: 'reader', child: _AiProgress(done: facts.done, total: facts.total, unit: facts.unit, line: facts.line)),
          if (facts.unit.startsWith('page') && _pages.length <= 8) ...[
            const SizedBox(height: 14),
            _PageRows(pages: _pages, drafts: _drafts),
          ],
        ] else if (needsDetails) ...[
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
        else if (unanswered > 0 && !_asking && _working == null)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InlineNotice('AI has not looked for ${f.count(unanswered, 'answer')} yet.', tone: Tone.ai, icon: Ph.scan),
            const SizedBox(height: 10),
            SecondaryButton('Find answers with AI', icon: Ph.scan, tint: aiAccentInk, onTap: _run),
          ]),
        if (_working != null && !_bulk) InlineNotice('$_workingText.', tone: Tone.ai, icon: Ph.scan),
        if (_asking && !reading) ...[
          InlineNotice(
            _secondPending == 1
                ? 'A stronger AI model is taking a second look at 1 question. You can carry on meanwhile.'
                : 'A stronger AI model is taking a second look at $_secondPending questions. You can carry on meanwhile.',
            tone: Tone.ai,
            icon: Ph.scan,
          ),
        ],
        if (_saved != null) ...[
          const SizedBox(height: 10),
          InlineNotice(_saved!, tone: Tone.success, icon: Ph.checkCircle),
        ],
        if (!needsDetails && !reading) ...[
          if (_pages.isNotEmpty) ...[
            const SizedBox(height: 18),
            _PagesStrip(
              pages: _pages,
              issues: issues,
              onOpen: (pg) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _PageView(url: '${pg['image_url']}', n: pg['page_no'] as int))),
            ),
          ],
          const SizedBox(height: 18),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(children: [
              for (final (i, (flt, name)) in tabs.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                SegChip(name, selected: _filter == flt, count: counts[flt], onTap: () => setState(() => _filter = flt)),
              ],
            ]),
          ),
          const SizedBox(height: 14),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                switch (_filter) {
                  _Filter.toCheck => live.isEmpty ? 'Questions appear here once AI has read the pages.' : 'Nothing needs you. Save the ready questions.',
                  _Filter.ready => 'Questions with their answer marked appear here.',
                  _Filter.other => 'No written-answer questions on this paper.',
                  _Filter.saved => 'Nothing saved yet.',
                  _Filter.skipped => 'No skipped questions.',
                },
                style: bodyStyle.copyWith(color: muted),
              ),
            ),
          for (final (i, d) in shown.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            _filter == _Filter.ready
                ? _ReadyRow(
                    d: d,
                    open: _openRows.contains('${d['id']}'),
                    onTap: () => setState(() => _openRows.contains('${d['id']}') ? _openRows.remove('${d['id']}') : _openRows.add('${d['id']}')),
                    expanded: card(d),
                  )
                : card(d),
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
      footer: _tests.isEmpty
          ? PrimaryButton('Publish as a test', leadingIcon: Ph.exam, busy: _making, onTap: _making ? null : () => _offerPublish(p))
          : SecondaryButton(_making ? 'Making the test' : 'Make another test from it', icon: Ph.exam, onTap: _making ? null : () => _offerPublish(p)),
      children: [
        const SizedBox(height: 12),
        Fig(f.count(n, 'question'), style: labelStyle.copyWith(fontSize: 12.5), numColor: ink),
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
          child: TextAction('See the questions as AI read them', onTap: () {
            setState(() {
              _review = true;
              _filter = _Filter.saved;
            });
          }),
        ),
      ],
    );
  }
}

/// The AI paper reader at work: how many pages are read (then how many answers are worked out), on the
/// one place the accent colour is for.
class _AiProgress extends StatelessWidget {
  const _AiProgress({required this.done, required this.total, required this.unit, required this.line});
  final int done;
  final int total;
  final String unit;
  final String line;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        decoration: BoxDecoration(color: aiAccentSoft, borderRadius: BorderRadius.circular(rHero)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Kicker('AI paper reader', color: aiAccentInk),
          const SizedBox(height: 12),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text('$done', style: numStyle(size: 40)),
            const SizedBox(width: 9),
            Flexible(child: Text(total > 0 ? 'of $total $unit' : unit, style: bodyStyle.copyWith(color: muted, fontWeight: FontWeight.w600, fontSize: 15))),
          ]),
          const SizedBox(height: 16),
          Track(total > 0 ? done / total : 0, color: aiAccent, trackColor: aiAccent.withValues(alpha: isDark ? 0.22 : 0.14)),
          const SizedBox(height: 12),
          Fig(line, style: bodyStyle.copyWith(color: body), numColor: ink),
        ]),
      );
}

/// The pages while they are read: done, being read, waiting.
class _PageRows extends StatelessWidget {
  const _PageRows({required this.pages, required this.drafts});
  final List<Map<String, dynamic>> pages;
  final List<Map<String, dynamic>> drafts;

  @override
  Widget build(BuildContext context) => Surface(
        shadow: e1,
        child: Column(children: [
          for (final (i, pg) in pages.indexed)
            Container(
              padding: const EdgeInsets.fromLTRB(17, 13, 17, 13),
              decoration: i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: hairline))),
              child: Builder(builder: (context) {
                final status = '${pg['ai_status']}';
                final n = drafts.where((d) => d['page_no'] == pg['page_no']).length;
                final ring = switch (status) {
                  'done' => Container(
                      width: 21,
                      height: 21,
                      decoration: BoxDecoration(color: success, shape: BoxShape.circle),
                      child: const Icon(Ph.check, size: 13, color: Colors.white),
                    ),
                  'reading' => Breathe(
                      child: Container(
                        width: 21,
                        height: 21,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: aiAccentInk, width: 1.8)),
                        child: Container(width: 7, height: 7, decoration: BoxDecoration(color: aiAccentInk, shape: BoxShape.circle)),
                      ),
                    ),
                  'failed' => Container(
                      width: 21,
                      height: 21,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: danger, width: 1.8)),
                      child: Icon(Ph.x, size: 12, color: danger),
                    ),
                  _ => Container(width: 21, height: 21, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: ringIdle, width: 1.8))),
                };
                return Row(children: [
                  ring,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Fig('Page ${pg['page_no']}', style: rowTitleStyle.copyWith(color: status == 'done' || status == 'reading' ? ink : muted)),
                      const SizedBox(height: 2),
                      Fig(
                        switch (status) {
                          'done' => n == 0 ? 'No questions here' : f.count(n, 'question'),
                          'reading' => 'Reading',
                          'failed' => 'Could not be read',
                          _ => 'Waiting',
                        },
                        style: labelStyle,
                      ),
                    ]),
                  ),
                ]);
              }),
            ),
        ]),
      );
}

/// The page photos in a row, each with a badge for the questions on it that still need the tutor.
class _PagesStrip extends StatelessWidget {
  const _PagesStrip({required this.pages, required this.issues, required this.onOpen});
  final List<Map<String, dynamic>> pages;
  final Map<int, int> issues;
  final void Function(Map<String, dynamic> page) onOpen;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 92,
        child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, padding: const EdgeInsets.only(top: 6, left: 4), children: [
          for (final (i, pg) in pages.indexed) ...[
            if (i > 0) const SizedBox(width: 12),
            Pressable(
              label: 'Open page ${pg['page_no']}',
              onTap: pg['image_url'] == null ? null : () => onOpen(pg),
              child: Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 62,
                  height: 84,
                  decoration: surface(radius: 10, shadow: e1),
                  clipBehavior: Clip.antiAlias,
                  child: pg['image_url'] == null ? null : Image.network('${pg['image_url']}', fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox()),
                ),
                Positioned(right: 5, bottom: 5, child: TagChip('${pg['page_no']}')),
                if ((issues[pg['page_no'] as int] ?? 0) > 0)
                  Positioned(
                    left: -6,
                    top: -6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: warning, borderRadius: BorderRadius.circular(rPill)),
                      child: Text('${issues[pg['page_no'] as int]}', style: numStyle(size: 10.5, color: Colors.white)),
                    ),
                  ),
              ]),
            ),
          ],
        ]),
      );
}

/// A ready question in one quiet row (its number, the question, where the answer came from, the answer);
/// a tap opens the whole card under it.
class _ReadyRow extends StatelessWidget {
  const _ReadyRow({required this.d, required this.open, required this.onTap, required this.expanded});
  final Map<String, dynamic> d;
  final bool open;
  final VoidCallback onTap;
  final Widget expanded;

  @override
  Widget build(BuildContext context) {
    final number = '${d['number_label'] ?? ''}'.replaceAll(RegExp(r'[.)\s]+$'), '');
    final source = d['answer_source'] as String?;
    final correct = d['correct_option'] as int?;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Pressable(
        onTap: onTap,
        label: 'Question $number',
        child: Container(
          padding: const EdgeInsets.fromLTRB(17, 13, 15, 13),
          decoration: surface(radius: rCard, shadow: e1),
          child: Row(children: [
            SizedBox(width: 24, child: Text(number.padLeft(2, '0'), style: numStyle(size: 12, weight: FontWeight.w600, color: faint))),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                MathText('${d['text']}', style: rowTitleStyle, maxLines: 2),
                const SizedBox(height: 2),
                Fig('${d['chapter'] ?? 'Page ${d['page_no']}'}', style: labelStyle, maxLines: 1),
              ]),
            ),
            const SizedBox(width: 10),
            if (source == 'ai') const TagChip('AI', tone: Tone.ai) else TagChip(source == 'key' ? 'Key' : 'You'),
            const SizedBox(width: 8),
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
              child: Text(correct == null ? '' : 'ABCD'[correct], style: tagStyle.copyWith(fontSize: 12, color: ink)),
            ),
          ]),
        ),
      ),
      AnimatedSize( // motion: approved
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: open ? Padding(padding: const EdgeInsets.only(top: gapRow), child: expanded) : const SizedBox(width: double.infinity),
      ),
    ]);
  }
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
        const SizedBox(height: 14),
        GroupedInputs(children: [
          BareField(controller: _name, placeholder: 'e.g. Half-yearly exam', capitalization: TextCapitalization.sentences),
        ]),
        const SizedBox(height: 18),
        PrimaryButton('Carry on', busy: _busy, onTap: gap == null ? _save : null, disabledReason: _busy ? null : gap),
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
      footer: PrimaryButton('Save', busy: _busy, onTap: gap == null ? _save : null, disabledReason: _busy ? null : gap),
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

/// One question as AI read it. A question that needs the tutor says why in one line and offers the likely
/// answers as buttons; one that is ready is quiet.
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

  static String _letter(int i) => 'ABCD'[i];

  /// The first two AI checks could not settle this one and a stronger model has yet to give its opinion.
  bool get _waiting => d['ai_votes'] != null && d['correct_option'] == null;

  bool get _needsFigure => d['needs_diagram'] == true && d['image_key'] == null;

  /// The option each check chose for a question it could not settle: writer, solver, checker, tiebreak (0 to 3).
  Map<String, int> get _picks => {
        for (final e in ((d['ai_picks'] as Map?) ?? const {}).entries)
          if (e.value is int && (e.value as int) >= 0 && (e.value as int) <= 3) '${e.key}': e.value as int,
      };

  /// The options AI would put forward, the one most checks chose first.
  List<int> get _candidates {
    final p = _picks;
    final votes = [p['solver'], p['checker'], p['tiebreak']].whereType<int>().toList();
    final seen = <int>[];
    for (final v in votes) {
      if (!seen.contains(v)) seen.add(v);
    }
    final order = {for (final (i, v) in seen.indexed) v: i};
    seen.sort((a, b) {
      final byVotes = votes.where((x) => x == b).length.compareTo(votes.where((x) => x == a).length);
      return byVotes != 0 ? byVotes : order[a]!.compareTo(order[b]!);
    });
    return seen;
  }

  /// The label at the card's top right.
  (String, Tone) get _tag {
    final correct = d['correct_option'] as int?;
    if (d['status'] == 'discarded') return ('Skipped', Tone.neutral);
    if (d['status'] == 'saved') return ('Saved', Tone.success);
    if (d['kind'] != 'mcq') return ('Not multiple choice', Tone.neutral);
    if (correct == null) {
      if (_needsFigure) return ('Needs a figure', Tone.warning);
      if (_waiting) return ('Second look', Tone.ai);
      return switch (d['ai_note']) {
        'disagree' || 'unsure' => ('AI is split', Tone.warning),
        'unclear' => ('Part unreadable', Tone.warning),
        'no_option' => ('May be misprinted', Tone.warning),
        _ => ('Mark the answer', Tone.warning),
      };
    }
    if (_needsFigure) return ('Needs a figure', Tone.warning);
    if (d['ai_note'] == 'writer_differs') return ('Check the answer', Tone.warning);
    return ('Ready', Tone.success);
  }

  /// One line on why this question is here, and whether the tutor has to act on it.
  (String, bool)? get _why {
    if (d['status'] == 'saved') return null;
    final correct = d['correct_option'] as int?;
    final p = _picks;
    final w = p['writer'];
    if (d['ai_note'] == 'duplicate') return ('Same as ${repeatOf ?? 'an earlier question'}, so it was skipped.', false);
    if (d['ai_note'] == 'in_bank') return ('You already have this question, so it was not saved again.', false);
    if (correct == null && _needsFigure) return ('AI cannot see figures. Add a photo of it, or skip the question.', true);
    if (correct == null && _waiting) return ('A stronger AI model is taking a second look. You can mark it yourself meanwhile.', false);
    return switch (d['ai_note']) {
      'unclear' => ('Part of this could not be read, so AI did not answer it. Check it against the page.', true),
      'no_option' => ('No option fits, so it may be misprinted. Check it against the page.', true),
      'disagree' => ('The AI checks chose different answers.${w == null ? '' : ' The question was written with ${_letter(w)}.'}', true),
      'unsure' => ('AI was not sure enough to mark this one.', true),
      'writer_differs' when correct != null => ('AI marked ${_letter(correct)}, but the question was written with ${w == null ? 'another option' : _letter(w)}. Check that ${_letter(correct)} is right.', true),
      _ => null,
    };
  }

  /// The small labels on an option that a check chose ("AI 1", "Writer").
  List<String> _chipsFor(int i) {
    final p = _picks;
    return [
      if (p['solver'] == i) 'AI 1',
      if (p['checker'] == i) 'AI 2',
      if (p['tiebreak'] == i) 'AI 3',
      if (p['writer'] == i) 'Writer',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final options = (d['options'] as List?)?.cast<String>() ?? const [];
    final correct = d['correct_option'] as int?;
    final saved = d['status'] == 'saved';
    final mcq = d['kind'] == 'mcq';
    final why = _why;
    final number = '${d['number_label'] ?? ''}'.replaceAll(RegExp(r'[.)\s]+$'), '');
    final label = number.isEmpty ? 'Q' : 'Q $number';
    final source = d['answer_source'] as String?;
    final sure = d['ai_confidence'] is num ? ((d['ai_confidence'] as num) * 100).round() : null;
    final (tagText, tagTone) = _tag;
    final showChips = !saved && mcq && (correct == null || d['ai_note'] == 'writer_differs');
    final draft = d['status'] == 'draft';

    // The buttons that settle a question that needs the tutor.
    final actions = <(String, bool, VoidCallback)>[];
    if (draft && mcq && correct == null) {
      if (_needsFigure) {
        if (onDiagram != null) actions.add(('Add the figure', true, onDiagram!));
        if (onDiscard != null) actions.add(('Skip', false, onDiscard!));
      } else if (d['ai_note'] == 'unclear') {
        if (onConfirm != null) actions.add(('Looks right', true, onConfirm!));
        if (onEdit != null) actions.add(('Edit', false, onEdit!));
      } else if (d['ai_note'] == 'no_option') {
        if (onEdit != null) actions.add(('Edit question', true, onEdit!));
        if (onDiscard != null) actions.add(('Skip', false, onDiscard!));
      } else if (!_waiting && onMark != null) {
        for (final (i, c) in _candidates.take(3).indexed) {
          actions.add(('Use ${_letter(c)}', i == 0, () => onMark!(c)));
        }
      }
    }

    return Surface(
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Kicker('$label · page ${d['page_no']}'),
          const Spacer(),
          TagChip(tagText, tone: tagTone),
        ]),
        const SizedBox(height: 11),
        MathText('${d['text']}', style: optionStyle.copyWith(fontWeight: FontWeight.w600, fontSize: 15)),
        if (d['image_url'] != null) ...[
          const SizedBox(height: 10),
          ClipRRect(borderRadius: BorderRadius.circular(rSmall), child: Image.network('${d['image_url']}', height: 140, errorBuilder: (_, _, _) => const SizedBox())),
        ],
        if (mcq) ...[
          const SizedBox(height: 8),
          for (final (i, o) in options.indexed)
            Pressable(
              onTap: onMark == null ? null : () => onMark!(i),
              label: 'Mark option ${_letter(i)} as right${correct == i ? ', marked' : ''}',
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
                  OptionMark(selected: correct == i, size: 24, letter: _letter(i), color: success, onColor: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: MathText(o,
                        style: bodyStyle.copyWith(fontSize: 14.5, color: correct == i ? ink : body, fontWeight: correct == i ? FontWeight.w600 : FontWeight.w500)),
                  ),
                  if (showChips)
                    for (final c in _chipsFor(i)) ...[const SizedBox(width: 5), TagChip(c, tone: Tone.ai)],
                ]),
              ),
            ),
          if (correct != null && !saved && (source == 'key' || source == 'ai'))
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 0, 0),
              child: Row(children: [
                Icon(source == 'ai' ? Ph.scan : Ph.check, size: 14, color: source == 'ai' ? aiAccentInk : muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Fig(
                    source == 'key' ? 'From the paper\'s answer key' : 'Worked out by AI${sure == null ? '' : ', $sure% sure'}',
                    style: labelStyle.copyWith(color: source == 'ai' ? aiAccentInk : muted),
                  ),
                ),
              ]),
            ),
        ],
        if (why != null)
          Padding(
            padding: EdgeInsets.fromLTRB(mcq ? 10 : 0, 10, 0, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(why.$2 ? Ph.warning : Ph.info, size: 14, color: why.$2 ? warning : muted),
              ),
              const SizedBox(width: 7),
              Expanded(child: Fig(why.$1, style: labelStyle.copyWith(color: why.$2 ? warning : muted))),
            ]),
          ),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(children: [
            for (final (i, a) in actions.indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(child: _CardButton(label: a.$1, primary: a.$2, onTap: a.$3)),
            ],
          ]),
        ],
        const SizedBox(height: 10),
        Container(height: 1, color: hairline),
        const SizedBox(height: 8),
        // The chapter takes what room is left and shortens itself, so a long chapter name never
        // pushes the edit and skip buttons off the card.
        Row(children: [
          Expanded(
            child: Row(children: [
              if (d['chapter'] != null) Flexible(child: Pressable(onTap: onChapter, label: 'Change chapter', child: TagChip('${d['chapter']}'))),
            ]),
          ),
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

/// A button inside a card that settles a question: the likeliest answer in black, the others quiet.
class _CardButton extends StatelessWidget {
  const _CardButton({required this.label, required this.primary, required this.onTap});
  final String label;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: label,
        onTap: onTap,
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary ? actionFill : fill,
            borderRadius: BorderRadius.circular(13),
            boxShadow: primary ? e2 : null,
          ),
          child: Text(label, style: buttonStyle.copyWith(fontSize: 13, color: primary ? actionInk : ink)),
        ),
      );
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
