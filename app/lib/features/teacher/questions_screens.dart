import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import '../../ui/tokens.dart';
import 'common.dart';
import 'subjects.dart';

// ---------------------------------------------------------------- bank

/// A question group's name: the paper category ("NCERT Exemplar"), or what the group is.
String questionGroupTitle(Map<String, dynamic> g, {bool othersToo = true}) => switch ('${g['key']}') {
      'library' => 'Ready-made',
      'manual' => 'Written by you',
      'papers' => othersToo ? 'Other uploaded papers' : 'Uploaded papers',
      _ => '${g['category']}',
    };

/// "Class 10", "Classes 9 and 10", "Classes 7 to 10".
String _classes(List classes) {
  final c = classes.cast<int>()..sort();
  if (c.isEmpty) return '';
  if (c.length == 1) return 'Class ${c.first}';
  final run = c.last - c.first == c.length - 1;
  return run && c.length > 2 ? 'Classes ${c.first} to ${c.last}' : 'Classes ${c.sublist(0, c.length - 1).join(', ')} and ${c.last}';
}

/// The Questions tab: where the questions came from, one row per source. A search looks across
/// every question at once.
class QuestionsScreen extends StatefulWidget {
  const QuestionsScreen({super.key});

  @override
  State<QuestionsScreen> createState() => _QuestionsScreenState();
}

class _QuestionsScreenState extends State<QuestionsScreen> with WidgetsBindingObserver, AutoRefresh<QuestionsScreen> {
  List<Map<String, dynamic>>? _groups;
  List<Map<String, dynamic>>? _found;
  String? _error;
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  Set<Area> get refreshAreas => {Area.questions, Area.papers};

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    markLoaded();
    final q = _search.text.trim();
    try {
      final g = await api.get('/teacher/question-groups');
      final found = q.isEmpty ? null : await api.get('/teacher/questions?q=${Uri.encodeQueryComponent(q)}');
      if (mounted) {
        setState(() {
          _groups = (g['groups'] as List).cast<Map<String, dynamic>>();
          _found = found == null ? null : (found['questions'] as List).cast<Map<String, dynamic>>();
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
    final groups = _groups;
    final total = groups?.fold<int>(0, (a, g) => a + (g['questions'] as int));
    final searching = _search.text.trim().isNotEmpty;
    return SafeArea(
      bottom: false,
      child: WithFloatingAdd(
        add: FloatingAdd('New question', onTap: () => _open('/t/questions/new')),
        child: PullToRefresh(
          onRefresh: _load,
          child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
            TabHeader(kicker: total == null ? 'Question bank' : f.count(total, 'question'), title: 'Questions'),
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
              child: GroupedInputs(children: [
                BareField(
                  controller: _search,
                  placeholder: 'Search every question',
                  action: TextInputAction.search,
                  onChanged: (_) {
                    setState(() {});
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 350), _load);
                  },
                ),
              ]),
            ),
            if (groups == null && _error != null)
              ErrorState(message: _error!, onRetry: _load)
            else if (groups == null)
              const LoadingState()
            else if (searching)
              ..._results()
            else if (groups.isEmpty)
              const EmptyState(
                icon: Ph.books,
                title: 'No questions yet',
                body: 'Upload a question paper in Upload and let AI type it out, or add a question by hand.',
              )
            else
              ..._groupList(groups),
            fabClearance,
          ]),
        ),
      ),
    );
  }

  List<Widget> _results() {
    final found = _found;
    if (found == null) return [const LoadingState()];
    if (found.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
          child: Text('No question has those words.', style: bodyStyle.copyWith(color: muted)),
        ),
      ];
    }
    return [
      SectionRule('Found', count: found.length),
      Rows([for (final q in found) QuestionRow(q: q, showGroup: true, onTap: () => _open('/t/questions/${q['id']}'))]),
    ];
  }

  /// Papers first, by category, then the teacher's own questions and the ready-made library.
  List<Widget> _groupList(List<Map<String, dynamic>> groups) {
    final cats = groups.where((g) => '${g['key']}'.startsWith('cat:')).toList()
      ..sort((a, b) => '${a['category']}'.toLowerCase().compareTo('${b['category']}'.toLowerCase()));
    final papers = [...cats, ...groups.where((g) => g['key'] == 'papers')];
    final others = [...groups.where((g) => g['key'] == 'manual'), ...groups.where((g) => g['key'] == 'library')];
    Widget row(Map<String, dynamic> g) {
      final key = '${g['key']}';
      final title = questionGroupTitle(g, othersToo: cats.isNotEmpty);
      final subjects = (g['subjects'] as List? ?? const []).cast<String>();
      return RowTile(
        leading: _GroupBadge(icon: switch (key) { 'library' => Ph.books, 'manual' => Ph.pencilSimple, _ => Ph.fileText }),
        title: title,
        meta: [
          f.count(g['questions'] as int, 'question'),
          if (key.startsWith('cat:') || key == 'papers') f.count(g['papers'] as int, 'paper'),
          _classes(g['classes'] as List),
          if (subjects.isNotEmpty) subjects.join(', '),
        ].where((s) => s.isNotEmpty).join(' · '),
        chevron: true,
        onTap: () => _open('/t/questions/in/${Uri.encodeComponent(key)}?title=${Uri.encodeQueryComponent(title)}'),
      );
    }

    return [
      if (papers.isNotEmpty) ...[
        SectionRule('From your papers', count: papers.length),
        Rows([for (final g in papers) row(g)]),
      ],
      if (others.isNotEmpty) ...[
        const SectionRule('Other questions'),
        Rows([for (final g in others) row(g)]),
      ],
    ];
  }
}

class _GroupBadge extends StatelessWidget {
  const _GroupBadge({required this.icon});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(11)),
        child: Icon(icon, size: 19, color: muted),
      );
}

/// Rows with the list gap, inside the gutter.
class Rows extends StatelessWidget {
  const Rows(this.children, {super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: Column(children: [
          for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: gapRow), c],
        ]),
      );
}

/// One question in a list: its text, where it is, and how often it is used.
class QuestionRow extends StatelessWidget {
  const QuestionRow({super.key, required this.q, required this.onTap, this.showGroup = false});
  final Map<String, dynamic> q;
  final VoidCallback onTap;

  /// Also say where it came from (a search spans every group).
  final bool showGroup;

  @override
  Widget build(BuildContext context) {
    final used = q['used_in'] as int;
    final from = switch (q['source']) {
      'paper' => q['paper'] == null ? 'From a paper' : '${q['paper']}',
      'library' => 'Ready-made',
      _ => 'Written by you',
    };
    return RowTile(
      titleWidget: MathText('${q['text']}', style: rowTitleStyle, maxLines: 2),
      meta: [
        q['subject'] == null ? 'Class ${q['class_level']}' : groupName(q['class_level'] as int, '${q['subject']}'),
        if (showGroup) from,
        if (showGroup && q['chapter'] != null) '${q['chapter']}',
        used > 0 ? 'in ${f.count(used, 'test')}' : 'not in a test yet',
      ].join(' · '),
      onTap: onTap,
    );
  }
}

/// One group's questions, with the class, subject and chapter filters. A paper group lists its
/// questions paper by paper, in printed order; the others go chapter by chapter.
class QuestionListScreen extends StatefulWidget {
  const QuestionListScreen({super.key, required this.group, required this.title});
  final String group;
  final String title;

  @override
  State<QuestionListScreen> createState() => _QuestionListScreenState();
}

class _QuestionListScreenState extends State<QuestionListScreen> with WidgetsBindingObserver, AutoRefresh<QuestionListScreen> {
  List<Map<String, dynamic>>? _rows;
  List<Subject> _subjects = [];
  List<ChapterRow> _chapters = [];
  String? _error;
  int? _class;
  String? _subject;
  String? _chapter;
  final _search = TextEditingController();
  Timer? _debounce;

  bool get _byPaper => widget.group == 'papers' || widget.group.startsWith('cat:');

  @override
  Set<Area> get refreshAreas => {Area.questions, Area.papers};

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  /// The subject the list is narrowed to; with only one subject, that one.
  String? get _subjectOrOnly => _subject ?? (_subjects.length == 1 ? _subjects.first.id : null);

  Future<void> _load() async {
    markLoaded();
    final params = [
      'group=${Uri.encodeQueryComponent(widget.group)}',
      if (_class != null) 'class=$_class',
      if (_subject != null) 'subject=$_subject',
      if (_chapter != null) 'chapter=$_chapter',
      if (_search.text.trim().isNotEmpty) 'q=${Uri.encodeQueryComponent(_search.text.trim())}',
    ];
    try {
      final r = await api.get('/teacher/questions?${params.join('&')}');
      final subjects = _subjects.isEmpty ? await loadSubjects() : _subjects;
      if (mounted) {
        setState(() {
          _rows = (r['questions'] as List).cast<Map<String, dynamic>>();
          _subjects = subjects;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// The chapters of the chosen class and subject, for the Chapter filter.
  Future<void> _loadChapters() async {
    final subject = _subjectOrOnly;
    if (_class == null || subject == null) {
      setState(() => _chapters = []);
      return;
    }
    try {
      final r = await api.get('/teacher/chapters?class=$_class&subject=$subject');
      if (mounted) setState(() => _chapters = (r['chapters'] as List).cast<ChapterRow>());
    } on ApiException {
      if (mounted) setState(() => _chapters = []);
    }
  }

  void _narrow({int? cls, String? subject}) {
    setState(() {
      _class = cls;
      _subject = subject;
      _chapter = null;
    });
    _loadChapters();
    _load();
  }

  Future<void> _open(String path) async {
    await context.push(path);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final showChapter = _class != null && _subjectOrOnly != null && _chapters.isNotEmpty;
    return PushedPanel(
      kicker: rows == null ? 'Questions' : (rows.length == 1000 ? 'Showing 1000' : f.count(rows.length, 'question')),
      title: widget.title,
      children: [
        const SizedBox(height: 14),
        FilterBar(padding: EdgeInsets.zero, children: [
          ClassFilter(value: _class, onChanged: (c) => _narrow(cls: c, subject: _subject)),
          if (_subjects.length > 1) SubjectFilter(subjects: _subjects, value: _subject, onChanged: (v) => _narrow(cls: _class, subject: v)),
          if (showChapter)
            ChapterFilter(
              chapters: _chapters,
              value: _chapter,
              subtitle: groupName(_class!, _subjects.firstWhere((s) => s.id == _subjectOrOnly).name),
              onChanged: (v) {
                setState(() => _chapter = v);
                _load();
              },
            ),
        ]),
        const SizedBox(height: 10),
        GroupedInputs(children: [
          BareField(
            controller: _search,
            placeholder: 'Search these questions',
            action: TextInputAction.search,
            onChanged: (_) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 350), _load);
            },
          ),
        ]),
        if (rows == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (rows == null)
          const LoadingState()
        else if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 24),
            child: Text('No questions here for these filters.', style: bodyStyle.copyWith(color: muted)),
          )
        else
          ..._grouped(rows),
      ],
    );
  }

  /// A section per paper (paper groups) or per chapter (the others). The API sorts to match.
  List<Widget> _grouped(List<Map<String, dynamic>> rows) {
    final out = <Widget>[];
    String keyOf(Map<String, dynamic> q) => _byPaper ? '${q['paper_id']}' : '${q['class_level']}|${q['subject_id']}|${q['chapter_id']}';
    final counts = <String, int>{};
    for (final q in rows) {
      counts.update(keyOf(q), (n) => n + 1, ifAbsent: () => 1);
    }
    String? lastKey;
    for (final q in rows) {
      final key = keyOf(q);
      if (key != lastKey) {
        final group = q['subject'] == null ? 'Class ${q['class_level']}' : groupName(q['class_level'] as int, '${q['subject']}');
        final chapter = q['chapter'] == null ? 'No chapter' : '${q['chapter']}';
        final label = _byPaper
            ? '${q['paper'] ?? 'Paper'} · $group'
            : (_class != null && _subjectOrOnly != null ? chapter : '$group · $chapter');
        out.add(SectionRule(label, count: counts[key], padding: const EdgeInsets.fromLTRB(0, 22, 0, 11)));
        lastKey = key;
      } else {
        out.add(const SizedBox(height: gapRow));
      }
      out.add(QuestionRow(q: q, onTap: () => _open('/t/questions/${q['id']}')));
    }
    return out;
  }
}

// ---------------------------------------------------------------- editor

/// Inserts self-contained `$...$` snippets so no LaTeX knowledge is needed.
const mathSnippets = <(String, String)>[
  ('a/b', r'$\frac{1}{2}$'),
  ('x²', r'$x^{2}$'),
  ('√', r'$\sqrt{2}$'),
  ('×', r'$\times$'),
  ('÷', r'$\div$'),
  ('π', r'$\pi$'),
  ('θ', r'$\theta$'),
  ('≤', r'$\le$'),
  ('≥', r'$\ge$'),
  ('≠', r'$\ne$'),
  ('°', r'$^\circ$'),
];

class MathToolbar extends StatelessWidget {
  const MathToolbar({super.key, required this.onInsert});
  final ValueChanged<String> onInsert;

  @override
  Widget build(BuildContext context) => ChipRow(padding: EdgeInsets.zero, children: [
        for (final (label, snippet) in mathSnippets)
          Pressable(
            onTap: () => onInsert(snippet),
            label: 'Insert $label',
            child: Container(
              height: 34,
              constraints: const BoxConstraints(minWidth: 42),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rSmall)),
              child: Text(label, style: optionStyle.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
      ]);
}

void insertInto(TextEditingController c, String text) {
  final sel = c.selection;
  final start = sel.isValid ? sel.start : c.text.length;
  final end = sel.isValid ? sel.end : c.text.length;
  c.value = TextEditingValue(
    text: c.text.replaceRange(start, end, text),
    selection: TextSelection.collapsed(offset: start + text.length),
  );
}

/// Picks a photo, compresses it on the phone and uploads it. Returns the storage key.
Future<({String key, Uint8List bytes})?> pickAndUploadImage(BuildContext context, ImageSource source) async {
  final file = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  final up = await api.post('/teacher/uploads');
  await api.putBytes('${up['put_url']}', bytes);
  return (key: '${up['key']}', bytes: bytes);
}

/// The last option in a chapter choice: opens "Add a chapter" instead of choosing one.
const _addChapterChoice = '+add';

class QuestionEditor extends StatefulWidget {
  const QuestionEditor({super.key, this.id});
  final String? id;

  @override
  State<QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<QuestionEditor> {
  final _text = TextEditingController();
  final _options = List.generate(4, (_) => TextEditingController());
  final _solution = TextEditingController();
  final _focus = List.generate(6, (_) => FocusNode());
  int _lastFocus = 0;
  int? _class;
  String? _subjectId;
  List<Subject> _subjects = [];
  String? _chapterId;
  int? _correct;
  num _marks = 1;
  String? _imageKey;
  String? _imageUrl;
  Uint8List? _imageBytes;
  List<Map<String, dynamic>> _chapters = [];
  bool _loading = false;
  bool _busy = false;
  int _usedIn = 0;

  @override
  void initState() {
    super.initState();
    for (final (i, f) in _focus.indexed) {
      f.addListener(() {
        if (f.hasFocus) _lastFocus = i;
      });
    }
    for (final c in [_text, _solution, ..._options]) {
      c.addListener(() => setState(() {}));
    }
    _loadSubjects();
    if (widget.id != null) _load();
  }

  Future<void> _loadSubjects() async {
    try {
      final subjects = await loadSubjects();
      if (!mounted) return;
      setState(() {
        _subjects = subjects;
        // New questions start in Maths; an existing one keeps its subject from _load.
        _subjectId ??= subjects.where((x) => x.isDefault).map((x) => x.id).firstOrNull;
      });
      _loadChapters();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  void dispose() {
    for (final c in [_text, _solution, ..._options]) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await api.get('/teacher/questions/${widget.id}');
      final q = Map<String, dynamic>.from(r['question']);
      _text.text = '${q['text']}';
      final opts = (q['options'] as List).cast<String>();
      for (var i = 0; i < 4; i++) {
        _options[i].text = opts[i];
      }
      _solution.text = '${q['solution'] ?? ''}';
      _class = q['class_level'] as int;
      _subjectId = q['subject_id'] as String?;
      _chapterId = q['chapter_id'] as String?;
      _correct = q['correct_option'] as int;
      _marks = q['marks'] as num;
      _imageKey = q['image_key'] as String?;
      _imageUrl = q['image_url'] as String?;
      _usedIn = q['used_in'] as int;
      await _loadChapters();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadChapters() async {
    if (_class == null || _subjectId == null) return;
    final r = await api.get('/teacher/chapters?class=$_class&subject=$_subjectId');
    if (mounted) setState(() => _chapters = (r['chapters'] as List).cast<Map<String, dynamic>>());
  }

  TextEditingController get _focused => switch (_lastFocus) {
        0 => _text,
        5 => _solution,
        final i => _options[i - 1],
      };

  Future<void> _addChapter() async {
    final c = TextEditingController();
    final name = await showCentredCard<String>(
      context,
      title: 'Add a chapter',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupedInputs(children: [
          BareField(controller: c, placeholder: 'Chapter name', autofocus: true, capitalization: TextCapitalization.words, onSubmitted: (v) => Navigator.of(ctx).pop(v)),
        ]),
        const SizedBox(height: 16),
        PrimaryButton('Add', onTap: () => Navigator.of(ctx).pop(c.text)),
      ]),
    );
    if (name == null || name.trim().isEmpty || _class == null) return;
    try {
      final r = await api.post('/teacher/chapters', {'class_level': _class, 'subject_id': _subjectId, 'name': name.trim()});
      await _loadChapters();
      setState(() => _chapterId = '${r['chapter']['id']}');
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _pickImage() async {
    final source = await showCentredCard<ImageSource>(
      context,
      title: 'Add a diagram',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecondaryButton('Take a photo', icon: Ph.camera, onTap: () => Navigator.of(ctx).pop(ImageSource.camera)),
        const SizedBox(height: 10),
        SecondaryButton('Choose from gallery', icon: Ph.images, onTap: () => Navigator.of(ctx).pop(ImageSource.gallery)),
      ]),
    );
    if (source == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final up = await pickAndUploadImage(context, source);
      if (up != null) {
        setState(() {
        _imageKey = up.key;
        _imageBytes = up.bytes;
        _imageUrl = null;
      });
      }
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _missing {
    if (_class == null) return 'Choose a class.';
    if (_subjectId == null) return 'Choose a subject.';
    if (_text.text.trim().isEmpty) return 'Type the question.';
    if (_options.any((o) => o.text.trim().isEmpty)) return 'Fill in all four options.';
    if (_correct == null) return 'Tap the circle next to the right answer.';
    return null;
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    final body = {
      'class_level': _class,
      'subject_id': _subjectId,
      'chapter_id': _chapterId,
      'text': _text.text.trim(),
      'options': [for (final o in _options) o.text.trim()],
      'correct_option': _correct,
      'solution': _solution.text.trim().isEmpty ? null : _solution.text.trim(),
      'marks': _marks,
      'image_key': _imageKey,
    };
    try {
      if (widget.id == null) {
        await api.post('/teacher/questions', body);
      } else {
        final r = await api.patch('/teacher/questions/${widget.id}', body);
        // A corrected answer re-marks the tests already written with this question.
        final n = (r['regraded'] as int?) ?? 0;
        if (n > 0 && mounted) {
          await showCentredCard<void>(
            context,
            title: 'Marks updated',
            builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Fig(
                '${n == 1 ? '1 test already written has' : '$n tests already written have'} this question. '
                '${n == 1 ? 'It was' : 'They were'} marked again with the new answer.',
                style: bodyStyle.copyWith(color: muted),
              ),
              const SizedBox(height: 18),
              PrimaryButton('OK', onTap: () => Navigator.of(ctx).pop()),
            ]),
          );
        }
      }
      if (mounted) context.pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmCard(
      context,
      title: 'Delete this question?',
      body: _usedIn > 0
          ? 'It is in ${_usedIn == 1 ? 'a test' : '$_usedIn tests'}. It will be taken out of ${_usedIn == 1 ? 'it' : 'them'} and deleted, unless students have written ${_usedIn == 1 ? 'it' : 'one of them'}.'
          : 'It will be removed from the question bank.',
      confirm: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await api.delete('/teacher/questions/${widget.id}');
      if (mounted) context.pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PushedPanel(title: 'Question', children: [LoadingState()]);
    final missing = _missing;
    return PushedPanel(
      kicker: widget.id == null ? 'Question bank' : (_usedIn > 0 ? 'Used in $_usedIn test${_usedIn == 1 ? '' : 's'}' : 'Question bank'),
      title: widget.id == null ? 'New question' : 'Edit question',
      headerTrailing: widget.id == null ? null : CircleBtn(icon: Ph.trash, label: 'Delete', tint: danger, onTap: _delete),
      footer: PrimaryButton(_busy ? 'Saving' : 'Save question', onTap: missing == null && !_busy ? _save : null, disabledReason: _busy ? null : missing),
      children: [
        const FormLabel('Class'),
        ClassField(
          value: _class,
          onChanged: (c) {
            setState(() {
              _class = c;
              _chapterId = null;
            });
            _loadChapters();
          },
        ),
        const FormLabel('Subject'),
        SubjectField(
          subjects: _subjects,
          value: _subjectId,
          onChanged: (v) {
            setState(() {
              _subjectId = v;
              _chapterId = null;
              _chapters = [];
            });
            _loadChapters();
          },
        ),
        if (_class != null && _subjectId != null) ...[
          const FormLabel('Chapter'),
          SelectField(
            value: _chapters.where((c) => c['id'] == _chapterId).map((c) => '${c['name']}').firstOrNull,
            placeholder: 'No chapter',
            onTap: () async {
              final c = await showChoices<String>(
                context,
                title: 'Chapter',
                subtitle: groupName(_class!, _subjects.where((s) => s.id == _subjectId).map((s) => s.name).firstOrNull ?? ''),
                options: [
                  const Choice(null, 'No chapter'),
                  for (final ch in _chapters) Choice('${ch['id']}', '${ch['name']}'),
                  const Choice(_addChapterChoice, 'Add a new chapter'),
                ],
                selected: _chapterId,
              );
              if (c == null) return;
              if (c.value == _addChapterChoice) {
                _addChapter();
              } else {
                setState(() => _chapterId = c.value);
              }
            },
          ),
        ],
        const FormLabel('Question'),
        GroupedInputs(children: [
          BareField(controller: _text, focusNode: _focus[0], placeholder: 'Type the question', maxLines: null, minLines: 2, capitalization: TextCapitalization.sentences),
        ]),
        const SizedBox(height: 10),
        MathToolbar(onInsert: (s) {
          insertInto(_focused, s);
          _focus[_lastFocus].requestFocus();
        }),
        const FormLabel('Options. Tap the circle next to the right answer.'),
        GroupedInputs(children: [
          for (var i = 0; i < 4; i++)
            Row(children: [
              const SizedBox(width: 13),
              Pressable(
                onTap: () => setState(() => _correct = i),
                label: 'Mark option ${'ABCD'[i]} as right',
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _correct == i ? success : null,
                    border: _correct == i ? null : Border.all(color: ringIdle, width: 1.8),
                  ),
                  child: _correct == i
                      ? const Icon(Ph.check, size: 16, color: Colors.white)
                      : Text('ABCD'[i], style: tagStyle.copyWith(fontSize: 12, color: muted)),
                ),
              ),
              Expanded(child: BareField(controller: _options[i], focusNode: _focus[i + 1], placeholder: 'Option ${'ABCD'[i]}')),
            ]),
        ]),
        const FormLabel('Preview'),
        Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            MathText(_text.text.isEmpty ? 'The question appears here' : _text.text, style: optionStyle.copyWith(color: _text.text.isEmpty ? faint : ink)),
            const SizedBox(height: 10),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 22, child: Text('ABCD'[i], style: tagStyle.copyWith(fontSize: 12, color: _correct == i ? success : muted))),
                  Expanded(child: MathText(_options[i].text.isEmpty ? '-' : _options[i].text, style: bodyStyle.copyWith(color: ink))),
                ]),
              ),
          ]),
        ),
        const FormLabel('Diagram (optional)'),
        if (_imageBytes != null || _imageUrl != null)
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(rSmall),
              child: _imageBytes != null ? Image.memory(_imageBytes!) : Image.network(_imageUrl!),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: CircleBtn(icon: Ph.x, label: 'Remove diagram', onTap: () => setState(() {
                _imageKey = null;
                _imageBytes = null;
                _imageUrl = null;
              })),
            ),
          ])
        else
          SecondaryButton('Add a diagram', icon: Ph.image, onTap: _busy ? null : _pickImage),
        const FormLabel('Worked solution (optional)'),
        GroupedInputs(children: [
          BareField(controller: _solution, focusNode: _focus[5], placeholder: 'Shown to students after they submit', maxLines: null, minLines: 2, capitalization: TextCapitalization.sentences),
        ]),
        const FormLabel('Marks'),
        ChipRow(padding: EdgeInsets.zero, children: [
          for (final m in [1, 2, 3, 4, 5]) SegChip('$m', selected: _marks == m, onTap: () => setState(() => _marks = m)),
        ]),
        if (widget.id != null) ...[
          const SizedBox(height: 30),
          Center(child: TextAction('Delete this question', color: danger, onTap: _delete)),
        ],
      ],
    );
  }
}
