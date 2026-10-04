import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import 'common.dart';
import 'subjects.dart';

String testState(Map<String, dynamic> t) {
  if (t['status'] != 'published') return 'draft';
  final now = DateTime.now();
  final opens = f.parseTime(t['opens_at']);
  final closes = f.parseTime(t['closes_at']);
  if (opens != null && now.isBefore(opens)) return 'upcoming';
  if (closes != null && !now.isBefore(closes)) return 'closed';
  return 'open';
}

String testMeta(Map<String, dynamic> t) {
  final parts = [
    t['subject'] == null ? 'Class ${t['class_level']}' : groupName(t['class_level'] as int, '${t['subject']}'),
    f.count(t['question_count'] as int, 'question'),
  ];
  final opens = f.parseTime(t['opens_at']);
  final closes = f.parseTime(t['closes_at']);
  switch (testState(t)) {
    case 'upcoming':
      parts.add('opens ${f.when(opens!)}');
    case 'open':
      if (closes != null) parts.add('closes ${f.when(closes)}');
    case 'closed':
      parts.add('closed ${f.when(closes!)}');
    default:
      parts.add('not published');
  }
  return parts.join(' · ');
}

// ---------------------------------------------------------------- list

class TestsScreen extends StatefulWidget {
  const TestsScreen({super.key});

  @override
  State<TestsScreen> createState() => _TestsScreenState();
}

class _TestsScreenState extends State<TestsScreen> {
  List<Map<String, dynamic>>? _rows;
  List<Subject> _subjects = [];
  String? _error;
  String _filter = 'open';
  int? _class;
  String? _subject;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/teacher/tests');
      final subjects = _subjects.isEmpty ? await loadSubjects() : _subjects;
      if (mounted) {
        setState(() {
          _rows = (r['tests'] as List).cast<Map<String, dynamic>>();
          _subjects = subjects;
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
    // The class and subject chips narrow the list; the status chips count within them.
    final all = _rows
        ?.where((t) => (_class == null || t['class_level'] == _class) && (_subject == null || t['subject_id'] == _subject))
        .toList();
    final counts = <String, int>{};
    for (final t in all ?? const <Map<String, dynamic>>[]) {
      counts.update(testState(t), (n) => n + 1, ifAbsent: () => 1);
    }
    final rows = all?.where((t) => _filter == 'all' || testState(t) == _filter).toList();
    return SafeArea(
      bottom: false,
      child: ListView(padding: EdgeInsets.zero, children: [
        TabHeader(
          kicker: all == null ? 'Tests' : f.count(all.length, 'test'),
          title: 'Tests',
          actions: [CircleBtn(icon: Ph.plus, filled: true, label: 'New test', onTap: () => _open('/t/tests/new'))],
        ),
        const SizedBox(height: 18),
        ChipRow(children: [
          for (final (k, label) in [('open', 'Open'), ('upcoming', 'Coming up'), ('closed', 'Closed'), ('draft', 'Drafts'), ('all', 'All')])
            SegChip(label, count: k == 'all' ? all?.length : counts[k] ?? 0, selected: _filter == k, onTap: () => setState(() => _filter = k)),
        ]),
        const SizedBox(height: 8),
        ClassChips(value: _class, allowAll: true, onChanged: (c) => setState(() => _class = c)),
        if (_subjects.length > 1) ...[
          const SizedBox(height: 8),
          SubjectChips(subjects: _subjects, value: _subject, allowAll: true, onChanged: (v) => setState(() => _subject = v)),
        ],
        const SizedBox(height: 16),
        if (all == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (all == null)
          const LoadingState()
        else if (rows!.isEmpty)
          EmptyState(
            icon: Ph.exam,
            title: 'No tests here',
            body: 'Build a test from your question bank and choose when it opens.',
            action: SizedBox(width: 200, child: PrimaryButton('New test', onTap: () => _open('/t/tests/new'))),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Column(children: [
              for (final (i, t) in rows.indexed) ...[
                if (i > 0) const SizedBox(height: gapRow),
                RowTile(
                  title: '${t['title']}',
                  meta: testMeta(t),
                  trailing: t['status'] == 'published'
                      ? Text('${t['submitted']}/${t['assigned']}', style: numStyle(size: 15))
                      : const TagChip('Draft'),
                  onTap: () => _open(t['status'] == 'published' ? '/t/tests/${t['id']}' : '/t/tests/${t['id']}/edit'),
                ),
              ],
            ]),
          ),
        navClearance,
      ]),
    );
  }
}

// ---------------------------------------------------------------- editor

class TestEditor extends StatefulWidget {
  const TestEditor({super.key, this.id});
  final String? id;

  @override
  State<TestEditor> createState() => _TestEditorState();
}

class _TestEditorState extends State<TestEditor> {
  final _title = TextEditingController();
  int? _class;
  String? _subjectId;
  List<Subject> _subjects = [];
  List<Map<String, dynamic>> _questions = [];
  int? _limit = 20;
  DateTime? _opens;
  DateTime? _closes;
  bool _shuffle = true;

  /// Who writes it: 'group' (the class's students who take the subject), 'class' or 'students'.
  String _audience = 'group';
  Set<String> _studentIds = {};
  List<Map<String, dynamic>> _classStudents = [];
  bool _published = false;
  int _attempts = 0;
  bool _loading = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() {}));
    _loadSubjects();
    if (widget.id != null) _load();
  }

  Future<void> _loadSubjects() async {
    try {
      final subjects = await loadSubjects();
      if (!mounted) return;
      setState(() {
        _subjects = subjects;
        // New tests start in Maths; an existing test keeps its subject from _load.
        _subjectId ??= subjects.where((x) => x.isDefault).map((x) => x.id).firstOrNull;
      });
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  String? get _subjectName {
    for (final x in _subjects) {
      if (x.id == _subjectId) return x.name;
    }
    return null;
  }

  /// Active students of the class who take the test's subject.
  int get _groupSize => _classStudents
      .where((s) => (s['subjects'] as List? ?? const []).any((x) => (x as Map)['id'] == _subjectId))
      .length;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await api.get('/teacher/tests/${widget.id}');
      final t = Map<String, dynamic>.from(r['test']);
      _title.text = '${t['title']}';
      _class = t['class_level'] as int;
      _subjectId = t['subject_id'] as String?;
      _limit = t['time_limit_min'] as int?;
      _opens = f.parseTime(t['opens_at']);
      _closes = f.parseTime(t['closes_at']);
      _shuffle = t['shuffle'] == true;
      _audience = t['assign_group'] == true ? 'group' : (t['assign_all'] == true ? 'class' : 'students');
      _published = t['status'] == 'published';
      _attempts = t['attempts'] as int;
      _questions = (r['questions'] as List).cast<Map<String, dynamic>>();
      _studentIds = {for (final s in (r['students'] as List)) '${s['id']}'};
      await _loadStudents();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadStudents() async {
    if (_class == null) return;
    final r = await api.get('/teacher/students?class=$_class');
    if (mounted) {
      setState(() => _classStudents = (r['students'] as List).cast<Map<String, dynamic>>().where((s) => s['active'] == true).toList());
    }
  }

  Future<void> _pickQuestions() async {
    if (_class == null || _subjectId == null) return;
    final picked = await Navigator.of(context).push<List<Map<String, dynamic>>>(PageRouteBuilder(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => QuestionPicker(classLevel: _class!, subjectId: _subjectId!, subjectName: _subjectName ?? '', selected: _questions),
    ));
    if (picked != null) setState(() => _questions = picked);
  }

  String? get _missing {
    if (_title.text.trim().isEmpty) return 'Give the test a name.';
    if (_class == null) return 'Choose a class.';
    if (_subjectId == null) return 'Choose a subject.';
    if (_questions.isEmpty) return 'Choose at least one question.';
    if (_opens != null && _closes != null && !_closes!.isAfter(_opens!)) return 'The closing time must be after the opening time.';
    if (_audience == 'students' && _studentIds.isEmpty) return 'Choose at least one student.';
    return null;
  }

  Future<void> _save({required bool publish}) async {
    setState(() => _busy = true);
    final body = {
      'title': _title.text.trim(),
      'class_level': _class,
      'question_ids': [for (final q in _questions) q['id']],
      'time_limit_min': _limit,
      'opens_at': _opens?.toUtc().toIso8601String(),
      'closes_at': _closes?.toUtc().toIso8601String(),
      'shuffle': _shuffle,
      'subject_id': _subjectId,
      'assign_all': _audience == 'class',
      'assign_group': _audience == 'group',
      'student_ids': _audience == 'students' ? _studentIds.toList() : <String>[],
    };
    try {
      final id = widget.id ?? '${(await api.post('/teacher/tests', body))['id']}';
      if (widget.id != null) await api.patch('/teacher/tests/$id', body);
      if (publish != _published || widget.id == null) await api.post('/teacher/tests/$id/publish', {'published': publish});
      if (mounted) context.pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PushedPanel(title: 'Test', children: [LoadingState()]);
    final missing = _missing;
    final locked = _attempts > 0;
    return PushedPanel(
      kicker: widget.id == null ? 'New test' : (_published ? 'Published' : 'Draft'),
      title: widget.id == null ? 'New test' : 'Edit test',
      footer: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PrimaryButton(
          _busy ? 'Saving' : (_published ? 'Save changes' : 'Publish test'),
          onTap: missing == null && !_busy ? () => _save(publish: true) : null,
          disabledReason: _busy ? null : missing,
        ),
        if (!_published && missing == null && !_busy)
          Center(child: TextAction('Save as a draft for now', onTap: () => _save(publish: false))),
      ]),
      children: [
        const SizedBox(height: 22),
        GroupedInputs(children: [
          BareField(controller: _title, placeholder: 'Test name, e.g. Unit test 3', capitalization: TextCapitalization.sentences),
        ]),
        const FormLabel('Class'),
        ClassChips(
          value: _class,
          padding: EdgeInsets.zero,
          onChanged: locked
              ? (_) {}
              : (c) {
                  setState(() {
                    if (c != _class) {
                      _questions = [];
                      _studentIds = {};
                    }
                    _class = c;
                  });
                  _loadStudents();
                },
        ),
        const FormLabel('Subject'),
        SubjectChips(
          subjects: _subjects,
          value: _subjectId,
          padding: EdgeInsets.zero,
          onChanged: locked
              ? (_) {}
              : (v) => setState(() {
                    if (v != _subjectId) _questions = [];
                    _subjectId = v;
                  }),
        ),
        FormLabel(_questions.isEmpty ? 'Questions' : 'Questions · ${_questions.length} chosen'),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InlineNotice('Students have started this test, so its questions cannot change.', tone: Tone.neutral, icon: Ph.lock),
          ),
        for (final (i, q) in _questions.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          RowTile(
            leading: Text((i + 1).toString().padLeft(2, '0'), style: numStyle(size: 13, color: muted)),
            titleWidget: MathText('${q['text']}', style: rowTitleStyle, maxLines: 2),
            meta: q['chapter'] == null ? null : '${q['chapter']}',
          ),
        ],
        if (!locked) ...[
          if (_questions.isNotEmpty) const SizedBox(height: 10),
          SecondaryButton(
            _questions.isEmpty ? 'Choose questions' : 'Change questions',
            icon: Ph.listChecks,
            onTap: _class == null || _subjectId == null ? null : _pickQuestions,
          ),
          if (_class == null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Choose a class first.', style: labelStyle)),
        ],
        const FormLabel('Time limit'),
        ChipRow(padding: EdgeInsets.zero, children: [
          for (final m in [null, 10, 15, 20, 30, 45, 60, 90])
            SegChip(m == null ? 'No limit' : '$m min', selected: _limit == m, onTap: () => setState(() => _limit = m)),
        ]),
        const FormLabel('Opens'),
        DayTimeChooser(value: _opens, noneLabel: 'Now', onChanged: (v) => setState(() => _opens = v)),
        const FormLabel('Closes'),
        DayTimeChooser(value: _closes, noneLabel: 'No closing time', onChanged: (v) => setState(() => _closes = v)),
        if (_opens != null || _closes != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Fig(
              [
                _opens == null ? 'Opens as soon as you publish' : 'Opens ${f.when(_opens!)}',
                _closes == null ? 'stays open' : 'closes ${f.when(_closes!)}',
              ].join(', '),
              style: labelStyle,
            ),
          ),
        const FormLabel('Order'),
        ChipRow(padding: EdgeInsets.zero, children: [
          SegChip('Shuffle for each student', selected: _shuffle, onTap: () => setState(() => _shuffle = true)),
          SegChip('Same order for all', selected: !_shuffle, onTap: () => setState(() => _shuffle = false)),
        ]),
        const FormLabel('Who writes it'),
        ChipRow(padding: EdgeInsets.zero, children: [
          SegChip(
            _class == null || _subjectName == null ? 'The group' : '${groupName(_class!, _subjectName!)} group',
            count: _class == null ? null : _groupSize,
            selected: _audience == 'group',
            onTap: () => setState(() => _audience = 'group'),
          ),
          SegChip(_class == null ? 'Whole class' : 'All of Class $_class', selected: _audience == 'class', onTap: () => setState(() => _audience = 'class')),
          SegChip('Chosen students', selected: _audience == 'students', onTap: () => setState(() => _audience = 'students')),
        ]),
        if (_audience == 'group' && _class != null && _subjectName != null && _groupSize == 0) ...[
          const SizedBox(height: 10),
          InlineNotice(
            'No Class $_class student takes $_subjectName yet, so nobody will see this test. Add $_subjectName to students in Students.',
            icon: Ph.warning,
          ),
        ],
        if (_audience == 'students') ...[
          const SizedBox(height: 10),
          if (_classStudents.isEmpty)
            Text(_class == null ? 'Choose a class first.' : 'No active students in Class $_class.', style: labelStyle)
          else
            for (final (i, s) in _classStudents.indexed) ...[
              if (i > 0) const SizedBox(height: 8),
              RowTile(
                leading: _Tick(on: _studentIds.contains(s['id'])),
                title: '${s['display_name']}',
                onTap: () => setState(() {
                  final id = '${s['id']}';
                  _studentIds.contains(id) ? _studentIds.remove(id) : _studentIds.add(id);
                }),
              ),
            ],
        ],
      ],
    );
  }
}

/// Completion ring used as a checkbox: idle ring, or filled with a tick.
class _Tick extends StatelessWidget {
  const _Tick({required this.on});
  final bool on;

  @override
  Widget build(BuildContext context) => Container(
        width: 21,
        height: 21,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: on ? actionFill : null,
          border: on ? null : Border.all(color: faint, width: 1.8),
        ),
        child: on ? Icon(Ph.check, size: 13, color: actionInk) : null,
      );
}

class QuestionPicker extends StatefulWidget {
  const QuestionPicker({super.key, required this.classLevel, required this.subjectId, required this.subjectName, required this.selected});
  final int classLevel;
  final String subjectId;
  final String subjectName;
  final List<Map<String, dynamic>> selected;

  @override
  State<QuestionPicker> createState() => _QuestionPickerState();
}

class _QuestionPickerState extends State<QuestionPicker> {
  List<Map<String, dynamic>>? _all;
  late final List<Map<String, dynamic>> _picked = [...widget.selected];
  String? _chapter;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/teacher/questions?class=${widget.classLevel}&subject=${widget.subjectId}');
      if (mounted) setState(() => _all = (r['questions'] as List).cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  bool _has(Map<String, dynamic> q) => _picked.any((p) => p['id'] == q['id']);

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final chapters = <String>{for (final q in all ?? const <Map<String, dynamic>>[]) if (q['chapter'] != null) '${q['chapter']}'}.toList()..sort();
    final shown = all?.where((q) => _chapter == null || q['chapter'] == _chapter).toList();
    return PushedPanel(
      kicker: groupName(widget.classLevel, widget.subjectName),
      title: 'Choose questions',
      footer: PrimaryButton(
        _picked.isEmpty ? 'Choose questions' : 'Use ${_picked.length} question${_picked.length == 1 ? '' : 's'}',
        onTap: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked),
        disabledReason: 'Tap questions to add them to the test.',
      ),
      children: [
        const SizedBox(height: 18),
        if (chapters.isNotEmpty)
          ChipRow(padding: EdgeInsets.zero, children: [
            SegChip('All chapters', selected: _chapter == null, onTap: () => setState(() => _chapter = null)),
            for (final c in chapters) SegChip(c, selected: _chapter == c, onTap: () => setState(() => _chapter = c)),
          ]),
        const SizedBox(height: 14),
        if (all == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (all == null)
          const LoadingState()
        else if (shown!.isEmpty)
          EmptyState(icon: Ph.books, title: 'No ${groupName(widget.classLevel, widget.subjectName)} questions', body: 'Add some in Questions or from a question paper first.')
        else
          for (final (i, q) in shown.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            RowTile(
              leading: _Tick(on: _has(q)),
              titleWidget: MathText('${q['text']}', style: rowTitleStyle, maxLines: 3),
              meta: q['chapter'] == null ? null : '${q['chapter']}',
              onTap: () => setState(() => _has(q) ? _picked.removeWhere((p) => p['id'] == q['id']) : _picked.add(q)),
            ),
          ],
      ],
    );
  }
}

// ---------------------------------------------------------------- results

class TestResultsScreen extends StatefulWidget {
  const TestResultsScreen({super.key, required this.id});
  final String id;

  @override
  State<TestResultsScreen> createState() => _TestResultsScreenState();
}

class _TestResultsScreenState extends State<TestResultsScreen> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.get('/teacher/tests/${widget.id}/results');
      if (mounted) {
        setState(() {
        _d = Map<String, dynamic>.from(d);
        _error = null;
      });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _studentActions(Map<String, dynamic> s) async {
    final submitted = s['status'] == 'submitted';
    final choice = await showCentredCard<String>(
      context,
      title: '${s['display_name']}',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (submitted) ...[
          SecondaryButton('Open answer sheet', icon: Ph.eye, onTap: () => Navigator.of(ctx).pop('sheet')),
          const SizedBox(height: 10),
        ],
        if (s['retake_pending'] == true)
          InlineNotice('A retake is already allowed. It starts when they open the test.', tone: Tone.neutral, icon: Ph.info)
        else if (submitted || s['status'] == 'missed')
          SecondaryButton('Allow a retake', icon: Ph.arrowCounterClockwise, onTap: () => Navigator.of(ctx).pop('retake'))
        else
          Fig(s['status'] == 'writing' ? 'They are writing this test now.' : 'They have not started this test yet.', style: bodyStyle.copyWith(color: muted)),
      ]),
    );
    if (!mounted) return;
    if (choice == 'sheet') context.push('/t/attempts/${s['attempt_id']}');
    if (choice == 'retake') {
      try {
        await api.post('/teacher/tests/${widget.id}/retake', {'student_id': s['id']});
        _load();
      } on ApiException catch (e) {
        if (mounted) showProblem(context, e);
      }
    }
  }

  Future<void> _togglePublish(bool published) async {
    final ok = await confirmCard(
      context,
      title: published ? 'Unpublish this test?' : 'Publish this test?',
      body: published ? 'Students will no longer see it. Results already written are kept.' : 'Students in the class will see it.',
      confirm: published ? 'Unpublish' : 'Publish',
      destructive: published,
    );
    if (!ok) return;
    try {
      await api.post('/teacher/tests/${widget.id}/publish', {'published': !published});
      _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  void _export(Map<String, dynamic> t, List<Map<String, dynamic>> students) {
    String cell(Object? v) => '"${'${v ?? ''}'.replaceAll('"', '""')}"';
    final lines = [
      ['Name', 'Class', 'Status', 'Marks', 'Out of', 'Percent', 'Minutes taken', 'Submitted at'].map(cell).join(','),
      for (final s in students)
        [
          s['display_name'],
          s['class_level'],
          s['status'],
          s['score'] == null ? '' : f.marks(s['score']),
          s['max_score'] == null ? '' : f.marks(s['max_score']),
          s['pct'] == null ? '' : ((s['pct'] as num) * 100).round(),
          s['time_taken_sec'] == null ? '' : ((s['time_taken_sec'] as int) / 60).toStringAsFixed(1),
          s['submitted_at'] == null ? '' : f.when(f.parseTime(s['submitted_at'])!),
        ].map(cell).join(','),
    ];
    final name = '${t['title']} results.csv'.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    SharePlus.instance.share(ShareParams(
      files: [XFile.fromData(utf8.encode(lines.join('\n')), mimeType: 'text/csv', name: name)],
      fileNameOverrides: [name],
      subject: '${t['title']} results',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return PushedPanel(title: 'Results', children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    final t = Map<String, dynamic>.from(d['test']);
    final sum = Map<String, dynamic>.from(d['summary']);
    final students = (d['students'] as List).cast<Map<String, dynamic>>();
    final questions = (d['questions'] as List).cast<Map<String, dynamic>>();
    final published = t['status'] == 'published';
    final closes = f.parseTime(t['closes_at']);
    final kicker = [t['subject'] == null ? 'Class ${t['class_level']}' : groupName(t['class_level'] as int, '${t['subject']}'), if (!published) 'unpublished' else if (closes != null) (closes.isAfter(DateTime.now()) ? 'closes ${f.when(closes)}' : 'closed ${f.when(closes)}')].join(' · ');

    return PushedPanel(
      kicker: kicker,
      title: '${t['title']}',
      headerTrailing: CircleBtn(icon: Ph.pencilSimple, label: 'Edit test', onTap: () async {
        await context.push('/t/tests/${widget.id}/edit');
        _load();
      }),
      footer: Row(children: [
        Expanded(child: SecondaryButton('Export', icon: Ph.export, onTap: students.isEmpty ? null : () => _export(t, students))),
        const SizedBox(width: 10),
        Expanded(child: SecondaryButton(published ? 'Unpublish' : 'Publish', icon: published ? Ph.eyeSlash : Ph.eye, onTap: () => _togglePublish(published))),
      ]),
      children: [
        const SizedBox(height: 22),
        StatGrid(
          label: 'Average',
          value: sum['average_pct'] == null ? '-' : f.percent(sum['average_pct'] as num),
          note: sum['high_pct'] == null ? 'No one has submitted yet' : 'High ${f.percent(sum['high_pct'] as num)} · low ${f.percent(sum['low_pct'] as num)}',
          small: [
            StatSmall('Submitted', '${sum['submitted']}/${sum['assigned']}'),
            StatSmall((sum['missed'] as int) > 0 ? 'Missed' : 'Writing now', '${(sum['missed'] as int) > 0 ? sum['missed'] : sum['writing']}'),
          ],
        ),
        SectionRule('Students', count: students.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        if (students.isEmpty) Text('No students are given this test.', style: bodyStyle.copyWith(color: muted)),
        for (final (i, s) in students.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          RowTile(
            leading: AppAvatar(name: '${s['display_name']}', seed: '${s['id']}'),
            title: '${s['display_name']}',
            meta: switch (s['status']) {
              'submitted' => 'Submitted ${f.when(f.parseTime(s['submitted_at'])!)} · ${f.duration(s['time_taken_sec'] as int)}'
                  '${(s['attempt_no'] as int) > 1 ? ' · retake' : ''}${s['auto_submitted'] == true ? ' · time ran out' : ''}',
              'writing' => 'Writing now',
              'missed' => 'Missed',
              _ => s['retake_pending'] == true ? 'Retake allowed' : 'Not started',
            },
            metaColor: s['status'] == 'missed' ? danger : null,
            trailing: switch (s['status']) {
              'submitted' => Text('${f.marks(s['score'])}/${f.marks(s['max_score'])}', style: numStyle(size: 15)),
              'writing' => const TagChip('Writing', tone: Tone.warning),
              _ => null,
            },
            onTap: () => _studentActions(s),
          ),
        ],
        SectionRule('Questions', count: questions.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        for (final (i, q) in questions.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          _QuestionStatRow(q: q),
        ],
      ],
    );
  }
}

class _QuestionStatRow extends StatelessWidget {
  const _QuestionStatRow({required this.q});
  final Map<String, dynamic> q;

  @override
  Widget build(BuildContext context) {
    final pct = q['correct_pct'] as num?;
    final wrong = q['most_picked_wrong'] as int?;
    final counts = (q['option_counts'] as List).cast<int>();
    final hard = pct != null && pct < 0.5;
    return RowTile(
      leading: Text('Q${q['n']}', style: numStyle(size: 13, color: muted)),
      titleWidget: MathText('${q['text']}', style: rowTitleStyle, maxLines: 2),
      meta: pct == null
          ? 'No answers yet'
          : 'Right answer ${'ABCD'[q['correct_option'] as int]}'
              '${wrong == null ? '' : ' · most wrong picked ${'ABCD'[wrong]} (${counts[wrong]})'}'
              '${(q['skipped'] as int) > 0 ? ' · ${q['skipped']} skipped' : ''}',
      metaColor: hard ? danger : null,
      trailing: Text(pct == null ? '-' : f.percent(pct), style: numStyle(size: 15, color: hard ? danger : ink)),
    );
  }
}
