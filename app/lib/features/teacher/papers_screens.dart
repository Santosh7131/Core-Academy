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
import 'questions_screens.dart' show MathToolbar, insertInto, pickAndUploadImage;

Route<T> _instant<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => page,
    );

// ---------------------------------------------------------------- list

class PapersScreen extends StatefulWidget {
  const PapersScreen({super.key});

  @override
  State<PapersScreen> createState() => _PapersScreenState();
}

class _PapersScreenState extends State<PapersScreen> {
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
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
    return SafeArea(
      bottom: false,
      child: ListView(padding: EdgeInsets.zero, children: [
        TabHeader(
          kicker: rows == null ? 'Question papers' : f.count(rows.length, 'paper'),
          title: 'Papers',
          actions: [CircleBtn(icon: Ph.plus, filled: true, label: 'Upload paper', onTap: () => _open('/t/papers/new'))],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
          child: InlineNotice(
            'Upload a question paper and AI types out its questions. You check each one and mark the right answer before it is saved.',
            tone: Tone.ai,
            icon: Ph.scan,
          ),
        ),
        const SizedBox(height: 16),
        if (rows == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (rows == null)
          const LoadingState()
        else if (rows.isEmpty)
          EmptyState(
            icon: Ph.scan,
            title: 'No papers yet',
            body: 'Photograph a question paper, or pick a PDF from WhatsApp or Files.',
            action: SizedBox(width: 200, child: PrimaryButton('Upload a paper', onTap: () => _open('/t/papers/new'))),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Column(children: [
              for (final (i, p) in rows.indexed) ...[
                if (i > 0) const SizedBox(height: gapRow),
                RowTile(
                  title: '${p['exam_name']}${p['year'] == null ? '' : ' ${p['year']}'}',
                  meta: [
                    'Class ${p['class_level']}',
                    if (p['school'] != null) '${p['school']}',
                    '${p['page_count']} page${p['page_count'] == 1 ? '' : 's'}',
                  ].join(' · '),
                  trailing: _status(p),
                  onTap: () => _open('/t/papers/${p['id']}'),
                ),
              ],
            ]),
          ),
        navClearance,
      ]),
    );
  }

  Widget _status(Map<String, dynamic> p) {
    final toCheck = p['to_check'] as int;
    if ((p['pages_read'] as int) < (p['page_count'] as int)) return const TagChip('Not read');
    if (toCheck > 0) return TagChip('$toCheck to check', tone: Tone.warning);
    return TagChip('${p['saved']} saved', tone: Tone.success);
  }
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
    if (_class == null) return 'Choose the class.';
    if (_exam.text.trim().isEmpty) return 'Name the paper, e.g. Half-yearly exam.';
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
    final years = [for (var y = DateTime.now().year; y > DateTime.now().year - 5; y--) y];
    return PushedPanel(
      kicker: 'Question paper',
      title: 'Upload paper',
      footer: PrimaryButton(
        _status ?? 'Upload and read with AI',
        onTap: missing == null && !_busy ? _upload : null,
        disabledReason: _busy ? null : missing,
      ),
      children: [
        const FormLabel('Class'),
        ClassChips(value: _class, padding: EdgeInsets.zero, onChanged: (c) => setState(() => _class = c)),
        const FormLabel('School'),
        ChipRow(padding: EdgeInsets.zero, children: [
          SegChip('Not from a school', selected: _schoolId == null, onTap: () => setState(() => _schoolId = null)),
          for (final s in _schools) SegChip('${s['name']}', selected: _schoolId == s['id'], onTap: () => setState(() => _schoolId = '${s['id']}')),
        ]),
        const FormLabel('Paper'),
        GroupedInputs(children: [
          BareField(controller: _exam, placeholder: 'Name, e.g. Half-yearly exam', capitalization: TextCapitalization.sentences),
        ]),
        const SizedBox(height: 10),
        ChipRow(padding: EdgeInsets.zero, children: [
          for (final y in years) SegChip('$y', selected: _year == y, onTap: () => setState(() => _year = y)),
          SegChip('No year', selected: _year == null, onTap: () => setState(() => _year = null)),
        ]),
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
  String? _error;
  String? _reading; // "Reading page 2 of 4"
  String? _readError;
  String? _saved;
  bool _saving = false;
  _Filter _filter = _Filter.toCheck;

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
    final id = await showCentredCard<String>(
      context,
      title: 'Chapter',
      builder: (ctx) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, c) in _chapters.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            RowTile(title: '${c['name']}', trailing: d['chapter_id'] == c['id'] ? Icon(Ph.check, size: 18, color: ink) : null, onTap: () => Navigator.of(ctx).pop('${c['id']}')),
          ],
          if (_chapters.isEmpty) Text('No chapters for this class yet. Add them in Settings.', style: bodyStyle.copyWith(color: muted)),
        ]),
      ),
    );
    if (id != null) _patch(d, {'chapter_id': id});
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
    final changed = await Navigator.of(context).push<Map<String, dynamic>>(_instant(DraftEditor(draft: d)));
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

    return PushedPanel(
      kicker: 'Question paper · Class ${p['class_level']}',
      title: _reading != null && live.isEmpty ? 'Reading' : '${live.length} questions',
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
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Fig(
              [
                '${p['exam_name']}${p['year'] == null ? '' : ' ${p['year']}'}',
                if (p['school'] != null) '${p['school']}',
                if (lastRead != null) 'read ${f.time(lastRead)}',
              ].join(' · '),
              style: labelStyle,
            ),
          ),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 84,
          child: ListView(scrollDirection: Axis.horizontal, clipBehavior: Clip.none, children: [
            for (final (i, pg) in _pages.indexed) ...[
              if (i > 0) const SizedBox(width: 10),
              Pressable(
                label: 'Open page ${pg['page_no']}',
                onTap: pg['image_url'] == null ? null : () => Navigator.of(context).push(_instant(_PageView(url: '${pg['image_url']}', n: pg['page_no'] as int))),
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
        ChipRow(padding: EdgeInsets.zero, children: [
          SegChip('To check', count: toCheck, selected: _filter == _Filter.toCheck, onTap: () => setState(() => _filter = _Filter.toCheck)),
          SegChip('Ready', count: ready, selected: _filter == _Filter.ready, onTap: () => setState(() => _filter = _Filter.ready)),
          SegChip('Not MCQ', count: other, selected: _filter == _Filter.other, onTap: () => setState(() => _filter = _Filter.other)),
          SegChip('Saved', count: saved, selected: _filter == _Filter.saved, onTap: () => setState(() => _filter = _Filter.saved)),
          SegChip('All', count: live.length, selected: _filter == _Filter.all, onTap: () => setState(() => _filter = _Filter.all)),
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
