import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import '../../ui/tokens.dart';
import 'common.dart';
import 'subjects.dart';
import 'questions_screens.dart' show MathToolbar, insertInto, pickAndUploadImage;

/// "Half-yearly exam 2025": a paper's name is what the teacher typed, plus its year.
String paperName(Map<String, dynamic> p) => '${p['exam_name']}${p['year'] == null ? '' : ' ${p['year']}'}';

String _paperGroup(Map<String, dynamic> p) =>
    p['subject'] == null ? 'Class ${p['class_level']}' : groupName(p['class_level'] as int, '${p['subject']}');

// ---------------------------------------------------------------- list

/// The Upload tab: the way in to the AI paper reader, then every paper uploaded so far, by name.
class PapersScreen extends StatefulWidget {
  const PapersScreen({super.key});

  @override
  State<PapersScreen> createState() => _PapersScreenState();
}

class _PapersScreenState extends State<PapersScreen> {
  List<Map<String, dynamic>>? _rows;
  List<Subject> _subjects = [];
  int? _class;
  String? _subject;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    loadSubjects().then((s) {
      if (mounted) setState(() => _subjects = s);
    }).catchError((_) {});
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/teacher/papers');
      if (mounted) {
        setState(() {
          _rows = (r['papers'] as List).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _open(String path) async {
    await context.push(path);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final shown = rows
        ?.where((p) => (_class == null || p['class_level'] == _class) && (_subject == null || p['subject_id'] == _subject))
        .toList();
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          TabHeader(kicker: rows == null ? 'Question papers' : f.count(rows.length, 'question paper'), title: 'Upload'),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
            child: _UploadButton(onTap: () => _open('/t/papers/new')),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter + 12, 10, gutter + 12, 0),
            child: Fig(
              'Photograph it or pick a PDF. AI types out the questions; you check each one and give the paper a name.',
              style: labelStyle.copyWith(fontSize: 12, height: 1.45),
              textAlign: TextAlign.center,
            ),
          ),
          if (rows != null && rows.isNotEmpty) ...[
            const SizedBox(height: 18),
            FilterBar(children: [
              ClassFilter(value: _class, onChanged: (c) => setState(() => _class = c)),
              if (_subjects.length > 1) SubjectFilter(subjects: _subjects, value: _subject, onChanged: (v) => setState(() => _subject = v)),
            ]),
          ],
          if (rows == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (rows == null)
            const LoadingState()
          else if (rows.isEmpty)
            const EmptyState(
              icon: Ph.fileText,
              title: 'No papers yet',
              body: 'Each paper you upload is kept here under its name, with the questions saved from it.',
            )
          else ...[
            SectionRule('Saved papers', count: shown!.length),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
                child: Fig('No papers for this class and subject.', style: bodyStyle.copyWith(color: muted)),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              child: Column(children: [
                for (final (i, p) in shown.indexed) ...[
                  if (i > 0) const SizedBox(height: gapRow),
                  RowTile(
                    leading: const _PaperBadge(),
                    title: paperName(p),
                    meta: [_paperGroup(p), if (p['school'] != null) '${p['school']}', _progress(p)].join(' · '),
                    trailing: _status(p),
                    onTap: () => _open('/t/papers/${p['id']}'),
                  ),
                ],
              ]),
            ),
          ],
          navClearance,
        ]),
      ),
    );
  }

  /// How far the paper has got. A number and its word never split across lines.
  String _progress(Map<String, dynamic> p) {
    String n(int k, String one) => f.count(k, one).replaceFirst(' ', '\u00A0');
    final unread = (p['page_count'] as int) - (p['pages_read'] as int);
    if (unread > 0) return '${n(unread, 'page')} not read yet';
    final questions = (p['saved'] as int) + (p['to_check'] as int);
    return questions == 0 ? n(p['page_count'] as int, 'page') : n(questions, 'question');
  }

  Widget _status(Map<String, dynamic> p) {
    final toCheck = p['to_check'] as int;
    if ((p['pages_read'] as int) < (p['page_count'] as int)) return const TagChip('Not read');
    if (toCheck > 0) return TagChip('$toCheck to check', tone: Tone.warning);
    if ((p['saved'] as int) > 0) return const TagChip('Ready', tone: Tone.success);
    return const TagChip('Nothing saved');
  }
}

/// The way in to the AI paper reader, in the one accent colour the reader owns.
class _UploadButton extends StatelessWidget {
  const _UploadButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        label: 'Upload a question paper',
        onTap: onTap,
        child: Container(
          height: 56,
          decoration: BoxDecoration(color: aiAccent, borderRadius: BorderRadius.circular(16), boxShadow: e4),
          alignment: Alignment.center,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Ph.scan, size: 20, color: Colors.white),
            const SizedBox(width: 9),
            Text('Upload a question paper', style: buttonStyle.copyWith(color: Colors.white, fontSize: 15)),
          ]),
        ),
      );
}

class _PaperBadge extends StatelessWidget {
  const _PaperBadge();

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(9)),
        child: Icon(Ph.fileText, size: 19, color: faint),
      );
}

// ---------------------------------------------------------------- upload

class UploadPaperScreen extends StatefulWidget {
  const UploadPaperScreen({super.key});

  @override
  State<UploadPaperScreen> createState() => _UploadPaperScreenState();
}

class _UploadPaperScreenState extends State<UploadPaperScreen> {
  final _exam = TextEditingController();
  int? _class;
  String? _subjectId;
  List<Subject> _subjects = [];
  String? _schoolId;
  int? _year = DateTime.now().year;
  List<Map<String, dynamic>> _schools = [];
  final List<Uint8List> _pages = [];
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _exam.addListener(() => setState(() {}));
    api.get('/teacher/schools').then((r) {
      if (mounted) setState(() => _schools = (r['schools'] as List).cast<Map<String, dynamic>>());
    }).catchError((_) {});
    loadSubjects().then((subjects) {
      if (mounted) {
        setState(() {
          _subjects = subjects;
          _subjectId ??= subjects.where((x) => x.isDefault).map((x) => x.id).firstOrNull;
        });
      }
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _exam.dispose();
    super.dispose();
  }

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
      final n = doc.pagesCount.clamp(0, 20);
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

  String? get _missing {
    if (_exam.text.trim().isEmpty) return 'Name the paper, e.g. Half-yearly exam.';
    if (_class == null) return 'Choose the class.';
    if (_subjectId == null) return 'Choose the subject.';
    if (_pages.isEmpty) return 'Add at least one page.';
    return null;
  }

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _status = 'Creating the paper';
    });
    try {
      final r = await api.post('/teacher/papers', {
        'class_level': _class,
        'subject_id': _subjectId,
        'school_id': _schoolId,
        'exam_name': _exam.text.trim(),
        'year': _year,
        'pages': _pages.length,
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
    final missing = _missing;
    return PushedPanel(
      kicker: 'Question paper',
      title: 'Upload paper',
      footer: PrimaryButton(
        _status ?? 'Upload and read with AI',
        onTap: missing == null && !_busy ? _upload : null,
        disabledReason: _busy ? null : missing,
      ),
      children: [
        const FormLabel('Name'),
        GroupedInputs(children: [
          BareField(controller: _exam, placeholder: 'Paper name, e.g. Half-yearly exam', capitalization: TextCapitalization.sentences),
        ]),
        const FormLabel('Class'),
        ClassField(value: _class, onChanged: (c) => setState(() => _class = c)),
        const FormLabel('Subject'),
        SubjectField(subjects: _subjects, value: _subjectId, onChanged: (v) => setState(() => _subjectId = v)),
        const FormLabel('School and year'),
        _SchoolYear(
          schools: _schools,
          schoolId: _schoolId,
          year: _year,
          onSchool: (v) => setState(() => _schoolId = v),
          onYear: (v) => setState(() => _year = v),
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
          Expanded(child: SecondaryButton('Camera', icon: Ph.camera, onTap: _busy ? null : _camera)),
          const SizedBox(width: 8),
          Expanded(child: SecondaryButton('Gallery', icon: Ph.images, onTap: _busy ? null : _gallery)),
          const SizedBox(width: 8),
          Expanded(child: SecondaryButton('PDF', icon: Ph.filePdf, onTap: _busy ? null : _pdf)),
        ]),
        const SizedBox(height: 10),
        Fig('Lay the paper flat in good light, with the whole page in the photo. Up to 20 pages.', style: labelStyle),
      ],
    );
  }
}

// ---------------------------------------------------------------- review

enum _Filter { toCheck, ready, other, saved, all }

const _filterLabels = {
  _Filter.toCheck: 'To check',
  _Filter.ready: 'Ready to save',
  _Filter.other: 'Not multiple choice',
  _Filter.saved: 'Saved',
  _Filter.all: 'All questions',
};

/// One uploaded paper. While AI drafts wait to be checked this is where they are checked;
/// once every question is saved it shows the paper as a named set that can become a test.
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
  String? _error;
  String? _reading; // "Reading page 2 of 4"
  String? _readError;
  String? _saved;
  bool _saving = false;
  bool _making = false;
  _Filter _filter = _Filter.toCheck;

  /// Looking at the AI drafts of a paper that is already a finished set.
  bool _review = false;

  @override
  void initState() {
    super.initState();
    _load().then((_) {
      if (widget.autoRead) _readAll();
    });
  }

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
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// Reads every page that is not done yet, one at a time.
  Future<void> _readAll() async {
    final todo = _pages.where((p) => p['ai_status'] != 'done').toList();
    setState(() => _readError = null);
    for (final (i, p) in todo.indexed) {
      if (!mounted) return;
      setState(() => _reading = 'Reading page ${p['page_no']}${todo.length > 1 ? ' (${i + 1} of ${todo.length})' : ''}');
      try {
        await api.post('/teacher/papers/${widget.id}/pages/${p['page_no']}/read', null, const Duration(minutes: 3));
      } on ApiException catch (e) {
        if (mounted) setState(() => _readError = e.message);
        break;
      }
      await _load();
    }
    if (mounted) setState(() => _reading = null);
  }

  bool _isReady(Map<String, dynamic> d) =>
      d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] != null && (d['needs_diagram'] != true || d['image_key'] != null);

  bool _matches(Map<String, dynamic> d) => switch (_filter) {
        _Filter.toCheck => d['status'] == 'draft' && d['kind'] == 'mcq' && !_isReady(d),
        _Filter.ready => _isReady(d),
        _Filter.other => d['status'] == 'draft' && d['kind'] == 'other',
        _Filter.saved => d['status'] == 'saved',
        _Filter.all => d['status'] != 'discarded',
      };

  Future<void> _patch(Map<String, dynamic> d, Map<String, dynamic> body) async {
    try {
      final r = await api.patch('/teacher/drafts/${d['id']}', body);
      final updated = Map<String, dynamic>.from(r['draft']);
      final ch = _chapters.where((c) => c['id'] == updated['chapter_id']);
      updated['chapter'] = ch.isEmpty ? null : ch.first['name'];
      setState(() => _drafts = [for (final x in _drafts) x['id'] == d['id'] ? updated : x]);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
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
    if (changed != null) _patch(d, changed);
  }

  Future<void> _discard(Map<String, dynamic> d) async {
    final ok = await confirmCard(context, title: 'Skip this question?', body: 'It will not be added to the question bank.', confirm: 'Skip it', destructive: true);
    if (ok) _patch(d, {'status': 'discarded'});
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final r = await api.post('/teacher/papers/${widget.id}/save');
      _saved = 'Saved ${r['saved']} question${r['saved'] == 1 ? '' : 's'} to the question bank.';
      await _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename(Map<String, dynamic> p) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => _PaperDetails(paper: p)));
    if (changed == true) _load();
  }

  Future<void> _openQuestion(Map<String, dynamic> q) async {
    await context.push('/t/questions/${q['id']}');
    _load();
  }

  /// Every saved question goes into a new draft test for the paper's class and subject, named
  /// after the paper. The test editor opens so the teacher can set the times and publish.
  Future<void> _makeTest(Map<String, dynamic> p) async {
    setState(() => _making = true);
    try {
      final n = _questions.length;
      // A minute and a half a question, rounded up to a limit the test editor offers.
      final want = (n * 1.5).ceil();
      final limit = const [20, 30, 45, 60, 90, 120, 180].firstWhere((m) => m >= want, orElse: () => 180);
      final r = await api.post('/teacher/tests', {
        'title': paperName(p),
        'class_level': p['class_level'],
        'subject_id': p['subject_id'],
        'question_ids': [for (final q in _questions) q['id']],
        'time_limit_min': limit,
        'shuffle': true,
        'assign_all': false,
        'assign_group': true,
      });
      if (!mounted) return;
      setState(() => _saved = 'Made the test "${paperName(p)}". It is in Tests.');
      await context.push('/t/tests/${r['id']}/edit');
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
    final other = live.where((d) => d['status'] == 'draft' && d['kind'] == 'other').length;
    final saved = live.where((d) => d['status'] == 'saved').length;
    final shown = live.where(_matches).toList();
    final unread = _pages.where((x) => x['ai_status'] != 'done').length;
    final lastRead = _pages.map((x) => f.parseTime(x['read_at'])).whereType<DateTime>().fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    final counts = {_Filter.toCheck: toCheck, _Filter.ready: ready, _Filter.other: other, _Filter.saved: saved, _Filter.all: live.length};

    // Nothing left to read, check or save: the paper is a finished set.
    final asSet = unread == 0 && _reading == null && toCheck == 0 && ready == 0 && _questions.isNotEmpty;
    if (asSet && !_review) return _asSet(p);

    return PopScope(
      canPop: !asSet,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _review = false);
      },
      child: _reviewPanel(p, live: live, shown: shown, counts: counts, ready: ready, toCheck: toCheck, unread: unread, lastRead: lastRead, asSet: asSet),
    );
  }

  Widget _reviewPanel(Map<String, dynamic> p,
      {required List<Map<String, dynamic>> live,
      required List<Map<String, dynamic>> shown,
      required Map<_Filter, int> counts,
      required int ready,
      required int toCheck,
      required int unread,
      required DateTime? lastRead,
      required bool asSet}) {
    return PushedPanel(
      kicker: 'Question paper · ${_paperGroup(p)}',
      title: _reading != null && live.isEmpty ? 'Reading' : '${live.length} questions',
      onBack: asSet ? () => setState(() => _review = false) : null,
      footer: PrimaryButton(
        _saving ? 'Saving' : (ready == 0 ? 'Save ready questions' : 'Save $ready ready question${ready == 1 ? '' : 's'}'),
        onTap: ready > 0 && !_saving ? _save : null,
        disabledReason: _saving
            ? null
            : toCheck > 0
                ? '$toCheck still need the right option marked'
                : (live.isEmpty ? 'Nothing to save yet' : 'Everything here is saved or skipped'),
      ),
      children: [
        const SizedBox(height: 8),
        Fig(
          [
            paperName(p),
            if (p['school'] != null) '${p['school']}',
            if (lastRead != null) 'read ${f.time(lastRead)}',
          ].join(' · '),
          style: labelStyle,
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
        if (_reading != null)
          InlineNotice('$_reading. This takes a few seconds a page.', tone: Tone.ai, icon: Ph.scan)
        else if (_readError != null)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InlineNotice(_readError!, tone: Tone.danger, icon: Ph.warning),
            const SizedBox(height: 10),
            SecondaryButton('Try reading again', icon: Ph.arrowsClockwise, onTap: _readAll),
          ])
        else if (unread > 0)
          Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InlineNotice('$unread page${unread == 1 ? ' has' : 's have'} not been read yet.', tone: Tone.ai, icon: Ph.scan),
            const SizedBox(height: 10),
            SecondaryButton('Read with AI', icon: Ph.scan, tint: aiAccentInk, onTap: _readAll),
          ])
        else
          const InlineNotice('Read by AI. Check each question and mark the right option before saving.', tone: Tone.ai, icon: Ph.scan),
        if (_saved != null) ...[
          const SizedBox(height: 10),
          InlineNotice(_saved!, tone: Tone.success, icon: Ph.checkCircle),
        ],
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
                _Filter.ready => 'Questions you have checked appear here.',
                _Filter.other => 'No written-answer questions on this paper.',
                _Filter.saved => 'Nothing saved yet.',
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
            onMark: d['status'] == 'draft' ? (o) => _patch(d, {'correct_option': o}) : null,
            onChapter: d['status'] == 'draft' ? () => _chooseChapter(d) : null,
            onEdit: d['status'] == 'draft' ? () => _edit(d) : null,
            onDiagram: d['status'] == 'draft' ? () => _addDiagram(d) : null,
            onDiscard: d['status'] == 'draft' ? () => _discard(d) : null,
          ),
        ],
      ],
    );
  }

  /// The paper as a named set of questions, ready to become a test.
  Widget _asSet(Map<String, dynamic> p) {
    final n = _questions.length;
    final group = _paperGroup(p);
    return PushedPanel(
      kicker: 'Question paper · $group',
      title: paperName(p),
      headerTrailing: CircleBtn(icon: Ph.pencilSimple, label: 'Rename paper', onTap: () => _rename(p)),
      footer: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PrimaryButton(
          _making ? 'Making the test' : 'Make a test from this paper',
          leadingIcon: Ph.exam,
          onTap: _making ? null : () => _makeTest(p),
        ),
        const SizedBox(height: 8),
        Fig('All $n question${n == 1 ? '' : 's'} go into a new draft test for $group.', style: labelStyle, textAlign: TextAlign.center),
      ]),
      children: [
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (p['school'] != null) TagChip('${p['school']}'),
          TagChip(f.count(n, 'question')),
          TagChip(f.count(_pages.length, 'page')),
        ]),
        if (_saved != null) ...[
          const SizedBox(height: 14),
          InlineNotice(_saved!, tone: Tone.success, icon: Ph.checkCircle),
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
                const SizedBox(height: 2),
                Fig(q['chapter'] == null ? 'No chapter' : '${q['chapter']}', style: labelStyle.copyWith(color: muted), maxLines: 1),
              ]),
            ),
          ]),
        ),
      );
}

/// Rename a paper, or correct its school and year. The class and subject stay: the questions
/// saved from it use them.
class _PaperDetails extends StatefulWidget {
  const _PaperDetails({required this.paper});
  final Map<String, dynamic> paper;

  @override
  State<_PaperDetails> createState() => _PaperDetailsState();
}

class _PaperDetailsState extends State<_PaperDetails> {
  late final _name = TextEditingController(text: '${widget.paper['exam_name']}');
  late String? _schoolId = widget.paper['school_id'] as String?;
  late int? _year = widget.paper['year'] as int?;
  List<Map<String, dynamic>> _schools = [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    api.get('/teacher/schools').then((r) {
      if (mounted) setState(() => _schools = (r['schools'] as List).cast<Map<String, dynamic>>());
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await api.patch('/teacher/papers/${widget.paper['id']}', {'exam_name': _name.text.trim(), 'year': _year, 'school_id': _schoolId});
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final empty = _name.text.trim().isEmpty;
    return PushedPanel(
      kicker: 'Question paper · ${_paperGroup(widget.paper)}',
      title: 'Rename paper',
      footer: PrimaryButton(
        _busy ? 'Saving' : 'Save',
        onTap: empty || _busy ? null : _save,
        disabledReason: empty ? 'Name the paper, e.g. Half-yearly exam.' : null,
      ),
      children: [
        const FormLabel('Name'),
        GroupedInputs(children: [
          BareField(controller: _name, placeholder: 'Paper name, e.g. Half-yearly exam', capitalization: TextCapitalization.sentences),
        ]),
        const FormLabel('School and year'),
        _SchoolYear(
          schools: _schools,
          schoolId: _schoolId,
          year: _year,
          onSchool: (v) => setState(() => _schoolId = v),
          onYear: (v) => setState(() => _year = v),
        ),
        const SizedBox(height: 10),
        Fig('The class and subject stay as they are, because the questions saved from this paper use them.', style: labelStyle),
      ],
    );
  }
}

/// A paper's school and year, side by side.
class _SchoolYear extends StatelessWidget {
  const _SchoolYear({required this.schools, required this.schoolId, required this.year, required this.onSchool, required this.onYear});
  final List<Map<String, dynamic>> schools;
  final String? schoolId;
  final int? year;
  final ValueChanged<String?> onSchool;
  final ValueChanged<int?> onYear;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now().year;
    final years = {for (var y = now; y > now - 5; y--) y, ?year}.toList()..sort((a, b) => b - a);
    return Row(children: [
      Expanded(
        child: SelectField(
          value: schools.where((s) => s['id'] == schoolId).map((s) => '${s['name']}').firstOrNull ?? 'Not from a school',
          onTap: () async {
            final c = await showChoices<String>(
              context,
              title: 'School',
              options: [const Choice(null, 'Not from a school'), for (final s in schools) Choice('${s['id']}', '${s['name']}')],
              selected: schoolId,
            );
            if (c != null) onSchool(c.value);
          },
        ),
      ),
      const SizedBox(width: 10),
      SizedBox(
        width: 120,
        child: SelectField(
          value: year == null ? 'No year' : '$year',
          onTap: () async {
            final c = await showChoices<int>(
              context,
              title: 'Year',
              options: [for (final y in years) Choice(y, '$y'), const Choice(null, 'No year')],
              selected: year,
            );
            if (c != null) onYear(c.value);
          },
        ),
      ),
    ]);
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({required this.d, required this.ready, this.onMark, this.onChapter, this.onEdit, this.onDiagram, this.onDiscard});
  final Map<String, dynamic> d;
  final bool ready;
  final ValueChanged<int>? onMark;
  final VoidCallback? onChapter;
  final VoidCallback? onEdit;
  final VoidCallback? onDiagram;
  final VoidCallback? onDiscard;

  @override
  Widget build(BuildContext context) {
    final options = (d['options'] as List?)?.cast<String>() ?? const [];
    final correct = d['correct_option'] as int?;
    final saved = d['status'] == 'saved';
    final mcq = d['kind'] == 'mcq';
    final needsDiagram = d['needs_diagram'] == true && d['image_key'] == null;
    final number = '${d['number_label'] ?? ''}'.replaceAll(RegExp(r'[.)\s]+$'), '');
    final label = number.isEmpty ? 'Q' : 'Q $number';
    return Surface(
      padding: const EdgeInsets.fromLTRB(17, 14, 17, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Kicker('$label · page ${d['page_no']}'),
          const SizedBox(width: 8),
          if (!saved && !ready) const TagChip('AI draft', tone: Tone.ai),
          const Spacer(),
          if (saved)
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
              label: 'Mark option ${'ABCD'[i]} as right',
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Container(
                    width: 21,
                    height: 21,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: correct == i ? success : null,
                      border: correct == i ? null : Border.all(color: ringIdle, width: 1.8),
                    ),
                    child: correct == i ? const Icon(Ph.check, size: 13, color: Colors.white) : null,
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: MathText(o, style: bodyStyle.copyWith(fontSize: 14.5, color: correct == i ? ink : body, fontWeight: correct == i ? FontWeight.w600 : FontWeight.w500))),
                ]),
              ),
            ),
        ],
        const SizedBox(height: 8),
        Container(height: 1, color: hairline),
        const SizedBox(height: 10),
        Row(children: [
          Pressable(
            onTap: onChapter,
            label: 'Change chapter',
            child: TagChip(d['chapter'] == null ? 'No chapter' : '${d['chapter']}'),
          ),
          const SizedBox(width: 8),
          if (d['chapter'] != null && d['ai_chapter_guess'] != null && !saved)
            Expanded(child: Text('chapter guessed by AI', style: labelStyle.copyWith(color: faint), maxLines: 1, overflow: TextOverflow.ellipsis))
          else
            const Spacer(),
          if (onDiagram != null && needsDiagram) TextAction('Add diagram', color: warning, onTap: onDiagram),
          if (onEdit != null) CircleBtn(icon: Ph.pencilSimple, size: 34, ground: fill, label: 'Edit question', onTap: onEdit),
          if (onDiscard != null) ...[
            const SizedBox(width: 8),
            CircleBtn(icon: Ph.trash, size: 34, ground: fill, tint: muted, label: 'Skip question', onTap: onDiscard),
          ],
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
