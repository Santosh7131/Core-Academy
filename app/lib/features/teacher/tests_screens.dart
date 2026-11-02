import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import 'common.dart';
import 'subjects.dart';
import '../../core/levels.dart';

String testState(Map<String, dynamic> t) {
  if (t['status'] != 'published') return 'draft';
  final now = DateTime.now();
  final opens = f.parseTime(t['opens_at']);
  final closes = f.parseTime(t['closes_at']);
  if (opens != null && now.isBefore(opens)) return 'upcoming';
  if (closes != null && !now.isBefore(closes)) return 'closed';
  // Everyone it was given to has handed it in and nobody is writing: it is finished, whatever the closing time says.
  if (t['everyone_done'] == true && ((t['writing'] as num?) ?? 0) == 0) return 'done';
  return 'open';
}

int _count(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// What a test row says under its name on a group's or a course's page.
String testMeta(Map<String, dynamic> t) {
  final closes = f.parseTime(t['closes_at']);
  final opens = f.parseTime(t['opens_at']);
  final q = f.count(_count(t['question_count']), 'question');
  return switch (testState(t)) {
    'open' => '$q · ${closes == null ? 'open' : 'closes ${f.whenDate(closes)}'}',
    'upcoming' => '$q · opens ${opens == null ? 'later' : f.whenDate(opens)}',
    'closed' => '$q · closed ${closes == null ? '' : f.whenDate(closes)}',
    'done' => '$q · all handed in',
    _ => '$q · not posted yet',
  };
}

/// The tag that says what state a test is in, in the words a tutor uses: [state] is what [testState] returns.
TagChip testStateTag(String state) => switch (state) {
      'open' => const TagChip('Open now', tone: Tone.success),
      'upcoming' => const TagChip('Coming up', strong: true),
      'draft' => const TagChip('Not posted'),
      _ => const TagChip('Finished', outlined: true),
    };

/// A test as a row: its name, [meta] under it, a tag for its state and, under the tag, how many people have handed it in (or how
/// many are writing it now). A test that has not opened yet has nobody to count, and a draft has not been posted.
class TestRow extends StatelessWidget {
  const TestRow({super.key, required this.t, required this.meta, required this.onTap, this.state});
  final Map<String, dynamic> t;
  final String meta;
  final VoidCallback onTap;

  /// The test's state when the caller already worked it out.
  final String? state;

  @override
  Widget build(BuildContext context) {
    final s = state ?? testState(t);
    final writing = s == 'open' ? _count(t['writing']) : 0;
    final counted = s == 'open' || s == 'done' || s == 'closed';
    return TaggedRow(
      title: '${t['title']}',
      meta: meta,
      tag: testStateTag(s),
      note: !counted ? null : (writing > 0 ? '$writing writing now' : '${_count(t['submitted'])}/${_count(t['assigned'])} handed in'),
      noteColor: writing > 0 ? warning : null,
      onTap: onTap,
    );
  }
}

/// The tests of a group or a course as one list, every row with a tag for its state: open now first, then coming up,
/// then not posted, then the finished ones (the first three, and the rest on a tap). [go] opens a test's page or,
/// for one that is not posted, its editor. [empty] is what the page says when it has no tests.
List<Widget> classTests(
  List<Map<String, dynamic>> tests, {
  required bool allFinished,
  required VoidCallback onToggleFinished,
  required void Function(String path) go,
  required String empty,
}) {
  if (tests.isEmpty) return [EmptyState(icon: Ph.exam, title: 'No tests yet', body: empty)];
  List<Map<String, dynamic>> of(String s) => tests.where((t) => testState(t) == s).toList();
  final finished = [...of('done'), ...of('closed')];
  final shown = [...of('open'), ...of('upcoming'), ...of('draft'), ...(allFinished ? finished : finished.take(3))];
  return [
    for (final (i, t) in shown.indexed) ...[
      if (i > 0) const SizedBox(height: gapRow),
      TestRow(t: t, meta: testMeta(t), onTap: () => go(t['status'] == 'published' ? '/t/tests/${t['id']}' : '/t/tests/${t['id']}/edit')),
    ],
    if (finished.length > 3) Center(child: TextAction(allFinished ? 'Show fewer' : 'Show all ${finished.length} finished tests', onTap: onToggleFinished)),
  ];
}

// ---------------------------------------------------------------- editor

class TestEditor extends StatefulWidget {
  /// [courseId] and [courseName] are for a new test of a course (an existing test says which it is itself).
  const TestEditor({super.key, this.id, this.courseId, this.courseName});
  final String? id;
  final String? courseId;
  final String? courseName;

  @override
  State<TestEditor> createState() => _TestEditorState();
}

class _TestEditorState extends State<TestEditor> {
  final _title = TextEditingController();
  int? _class;
  String? _subjectId;

  /// A course's test has no class and no subject: it goes to the people of its course.
  String? _courseId;
  String? _courseName;
  int? _courseSize;
  bool get _isCourse => _courseId != null;
  List<Subject> _subjects = [];
  List<Map<String, dynamic>> _questions = [];
  int? _limit = 20;
  DateTime? _opens;
  DateTime? _closes;
  bool _shuffle = true;
  bool _allQuestions = false;

  /// Who writes it: 'group' (the class's students who take the subject) or 'students' (some of them).
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
    _courseId = widget.courseId;
    _courseName = widget.courseName;
    if (_isCourse) _loadCourseSize();
    _loadSubjects();
    // Every test closes: a new one starts with a closing time.
    if (widget.id == null) _closes = defaultClosing();
    if (widget.id != null) _load();
  }

  Future<void> _loadSubjects() async {
    try {
      final subjects = await loadSubjects();
      if (!mounted) return;
      setState(() {
        _subjects = subjects;
        // New tests start in Maths; an existing test keeps its subject from _load. A course's test has none.
        if (!_isCourse) _subjectId ??= subjects.where((x) => x.isDefault).map((x) => x.id).firstOrNull;
      });
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  /// How many people the course has now: they are who the test goes to.
  Future<void> _loadCourseSize() async {
    try {
      final r = await api.get('/teacher/courses/$_courseId');
      if (mounted) {
        setState(() {
          _courseSize = _count(r['course']['people']);
          _courseName = '${r['course']['name']}';
        });
      }
    } on ApiException {
      // The size is only a warning; the test can still be saved.
    }
  }

  String? get _subjectName {
    for (final x in _subjects) {
      if (x.id == _subjectId) return x.name;
    }
    return null;
  }

  /// Active students of the class who take the test's subject: the only ones a test can go to.
  List<Map<String, dynamic>> get _group =>
      _classStudents.where((s) => (s['subjects'] as List? ?? const []).any((x) => (x as Map)['id'] == _subjectId)).toList();

  int get _groupSize => _group.length;

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
      _courseId = t['course_id'] as String?;
      _courseName = t['course'] as String?;
      _class = t['class_level'] as int?;
      _subjectId = t['subject_id'] as String?;
      _limit = t['time_limit_min'] as int?;
      _opens = f.parseTime(t['opens_at']);
      _closes = f.parseTime(t['closes_at']);
      _published = t['status'] == 'published';
      if (_closes == null && !_published) _closes = defaultClosing();
      _shuffle = t['shuffle'] == true;
      // A whole-class test from before groups now goes to its group.
      _audience = t['assign_group'] == true || t['assign_all'] == true ? 'group' : 'students';
      _published = t['status'] == 'published';
      _attempts = t['attempts'] as int;
      _questions = (r['questions'] as List).cast<Map<String, dynamic>>();
      _studentIds = {for (final s in (r['students'] as List)) '${s['id']}'};
      if (_isCourse) {
        await _loadCourseSize();
      } else {
        await _loadStudents();
      }
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
    if (!_isCourse && (_class == null || _subjectId == null)) return;
    final picked = await Navigator.of(context).push<List<Map<String, dynamic>>>(MaterialPageRoute(
      builder: (_) => _isCourse
          ? QuestionPicker(courseId: _courseId, courseName: _courseName, selected: _questions)
          : QuestionPicker(classLevel: _class, subjectId: _subjectId, subjectName: _subjectName ?? '', selected: _questions),
    ));
    if (picked != null) setState(() => _questions = picked);
  }

  String? get _missing {
    if (_title.text.trim().isEmpty) return 'Give the test a name.';
    if (!_isCourse && _class == null) return 'Choose a class.';
    if (!_isCourse && _subjectId == null) return 'Choose a subject.';
    if (_questions.isEmpty) return 'Choose at least one question.';
    if (_closes == null) return 'Choose when the test closes.';
    if (_opens != null && !_closes!.isAfter(_opens!)) return 'The closing time must be after the opening time.';
    if (!_isCourse && _audience == 'students' && !_group.any((s) => _studentIds.contains(s['id']))) return 'Choose at least one student.';
    return null;
  }

  Future<void> _save({required bool publish}) async {
    setState(() => _busy = true);
    final shared = {
      'title': _title.text.trim(),
      'question_ids': [for (final q in _questions) q['id']],
      'time_limit_min': _limit,
      'opens_at': _opens?.toUtc().toIso8601String(),
      'closes_at': _closes?.toUtc().toIso8601String(),
      'shuffle': _shuffle,
    };
    // A course's test goes to the people of its course; a group's to its class, or to students chosen from it.
    final body = _isCourse
        ? {...shared, 'course_id': _courseId}
        : {
            ...shared,
            'class_level': _class,
            'subject_id': _subjectId,
            'assign_all': false,
            'assign_group': _audience == 'group',
            'student_ids': _audience == 'students' ? [for (final s in _group) if (_studentIds.contains(s['id'])) s['id']] : <String>[],
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

  /// The time limits offered as buttons; "Other" has the rest.
  static const _limitChoices = [15, 20, 30, 45, 60];

  /// Changes a start or an end: its day and its time, chosen in a card, kept when Done is tapped.
  Future<void> _changeWhen(String title, DateTime? value, ValueChanged<DateTime?> set, {String? noneLabel}) async {
    var draft = value;
    await showCentredCard<void>(
      context,
      title: title,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setCard) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DayTimeChooser(value: draft, noneLabel: noneLabel, onChanged: (v) => setCard(() => draft = v)),
          const SizedBox(height: 20),
          PrimaryButton('Done', onTap: () {
            set(draft);
            Navigator.of(ctx).pop();
          }),
        ]),
      ),
    );
  }

  /// Any time to finish, for the ones the buttons do not have.
  Future<void> _otherLimit() async {
    final c = await showChoices<int>(
      context,
      title: 'Time to finish',
      options: [
        const Choice(-1, 'No limit'),
        for (final m in {5, 10, 15, 20, 25, 30, 40, 45, 50, 60, 75, 90, 120, 150, 180, ?_limit}.toList()..sort()) Choice(m, '$m min'),
      ],
      selected: _limit ?? -1,
    );
    if (c?.value != null) setState(() => _limit = c!.value == -1 ? null : c.value);
  }

  /// Who the test goes to, in a few words.
  String get _whoValue {
    if (_isCourse) {
      final size = _courseSize;
      return '${_courseName == null ? 'Everyone in the course' : 'Everyone in $_courseName'}${size == null ? '' : ' · ${f.count(size, 'person', 'people')}'}';
    }
    if (_class == null || _subjectName == null) return 'Choose a class and subject first';
    if (_groupSize == 0) return 'No students in the group yet';
    if (_audience == 'group') return _groupSize == 1 ? 'The 1 student in the group' : 'All $_groupSize students';
    final chosen = _group.where((s) => _studentIds.contains(s['id'])).length;
    return '$chosen of ${f.count(_groupSize, 'student')}';
  }

  Future<void> _chooseWho() async {
    final r = await Navigator.of(context).push<({String audience, Set<String> ids})>(
      MaterialPageRoute(builder: (_) => _AudienceScreen(group: _group, audience: _audience, ids: _studentIds)),
    );
    if (r != null) {
      setState(() {
        _audience = r.audience;
        _studentIds = r.ids;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PushedPanel(title: 'Test', children: [LoadingState()]);
    final missing = _missing;
    final locked = _attempts > 0;
    final isNew = widget.id == null;
    // Questions come from the group's class and subject (a course has its own), so those are chosen first.
    final canPick = _isCourse || (_class != null && _subjectId != null);
    final chips = {..._limitChoices, ?_limit}.toList()..sort();
    const rule = EdgeInsets.fromLTRB(0, 26, 0, 11);
    final line = labelStyle.copyWith(fontSize: 13, fontWeight: FontWeight.w600);
    return PushedPanel(
      kicker: isNew
          ? (_isCourse && _courseName != null ? 'New test · $_courseName' : 'New test')
          : _isCourse
              ? '${_courseName == null ? '' : '$_courseName · '}${_published ? 'Posted' : 'Not posted yet'}'
              : '${_class != null && _subjectName != null ? '${groupName(_class!, _subjectName!)} · ' : ''}${_published ? 'Posted' : 'Not posted yet'}',
      title: isNew ? 'New test' : 'Test settings',
      footer: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PrimaryButton(
          _published ? 'Save changes' : 'Post test',
          busy: _busy,
          onTap: missing == null ? () => _save(publish: true) : null,
          disabledReason: _busy ? null : missing,
        ),
        if (!_published && missing == null && !_busy)
          Center(child: TextAction('Save as a draft for now', onTap: () => _save(publish: false))),
      ]),
      children: [
        if (isNew && !_isCourse) ...[
          // A new group's test: its class and subject first, because they decide which questions can be chosen.
          const SizedBox(height: 22),
          ClassField(
            value: _class,
            enabled: !locked,
            onChanged: (c) {
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
          const SizedBox(height: 10),
          SubjectField(
            subjects: _subjects,
            value: _subjectId,
            enabled: !locked,
            onChanged: (v) => setState(() {
              if (v != _subjectId) _questions = [];
              _subjectId = v;
            }),
          ),
          const SizedBox(height: 14),
        ] else
          const SizedBox(height: 16),
        // The test in one card: its name, when it opens, how many questions it has.
        Surface(
          shadow: e1,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            BareField(
              controller: _title,
              placeholder: 'Test name, e.g. Unit test 3',
              maxLength: 100,
              capitalization: TextCapitalization.sentences,
              style: rowTitleStyle.copyWith(fontWeight: FontWeight.w700, fontSize: 17),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(17, 0, 15, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Ph.calendarBlank, size: 16, color: faint)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(TextSpan(style: line, children: [
                      const TextSpan(text: 'Opens '),
                      figSpan(_opens == null ? 'as soon as you post it' : f.whenTitle(_opens!), line.copyWith(color: ink)),
                    ])),
                  ),
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  Icon(Ph.listChecks, size: 16, color: faint),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Fig(
                      _questions.isEmpty ? (canPick ? 'No questions yet' : 'Choose a class and subject first') : f.count(_questions.length, 'question'),
                      style: line.copyWith(color: _questions.isEmpty ? muted : ink),
                    ),
                  ),
                  if (!locked) TextAction(_questions.isEmpty ? 'Choose' : 'Change', color: canPick ? ink : faint, onTap: canPick ? _pickQuestions : null),
                ]),
              ]),
            ),
          ]),
        ),
        if (locked)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: InlineNotice('Students have started this test, so its questions cannot change.', tone: Tone.neutral, icon: Ph.lock),
          ),
        if (_questions.isNotEmpty)
          Center(
            child: TextAction(_allQuestions ? 'Hide the questions' : 'See the questions', onTap: () => setState(() => _allQuestions = !_allQuestions)),
          ),
        if (_allQuestions)
          for (final (i, q) in _questions.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            RowTile(
              leading: Text((i + 1).toString().padLeft(2, '0'), style: numStyle(size: 13, color: muted)),
              titleWidget: MathText('${q['text']}', style: rowTitleStyle, maxLines: 2),
              meta: q['chapter'] == null ? null : '${q['chapter']}',
            ),
          ],
        SectionRule('When', padding: rule),
        _SettingRow(
          label: 'Opens',
          value: _opens == null ? 'As soon as you post it' : f.whenTitle(_opens!),
          onTap: () => _changeWhen('Opens', _opens, (v) => setState(() => _opens = v), noneLabel: 'Now'),
        ),
        const SizedBox(height: 8),
        _SettingRow(
          label: 'Closes',
          value: _closes == null ? 'Choose when it closes' : f.whenTitle(_closes!),
          onTap: () => _changeWhen('Closes', _closes, (v) => setState(() => _closes = v)),
        ),
        SectionRule('Time to finish, in minutes', padding: rule, trailing: TextAction('Other', onTap: _otherLimit)),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _TimeChip('No limit', selected: _limit == null, onTap: () => setState(() => _limit = null)),
          for (final m in chips) _TimeChip('$m', selected: _limit == m, onTap: () => setState(() => _limit = m)),
        ]),
        SectionRule('Who and how', padding: rule),
        // Nobody to choose between for a course, or before a class and subject, or for a group with no students.
        _SettingRow(value: _whoValue, onTap: _isCourse || _class == null || _subjectName == null || _groupSize == 0 ? null : _chooseWho),
        if (_isCourse) ...[
          const SizedBox(height: 10),
          // A course's test goes to everyone in the course: there is no one to choose.
          if (_courseSize == 0)
            InlineNotice('No one is in this course yet, so nobody will see this test. Add people to the course first.', icon: Ph.warning)
          else
            Fig('People added to the course before it closes get the test too.', style: labelStyle),
        ] else if (_audience == 'group' && _class != null && _subjectName != null && _groupSize == 0) ...[
          const SizedBox(height: 10),
          InlineNotice(
            'No ${className(_class)} student takes $_subjectName yet, so nobody will see this test. Add students to the group first.',
            icon: Ph.warning,
          ),
        ],
        // A little more room after a note about the people, so it stays with the row above it.
        SizedBox(height: _isCourse || (_audience == 'group' && _class != null && _subjectName != null && _groupSize == 0) ? 14 : 8),
        _SwitchRow(label: 'Mix the questions up for each student', on: _shuffle, onChanged: (v) => setState(() => _shuffle = v)),
        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Fig(
            'Students see their marks and the right answers as soon as they hand it in.',
            style: labelStyle.copyWith(fontSize: 11.5, fontWeight: FontWeight.w600, height: 1.45),
            textAlign: TextAlign.center,
          ),
        ),
        if (widget.id != null) ...[
          const SizedBox(height: 30),
          Center(child: TextAction('Delete this test', color: danger, onTap: _delete)),
        ],
      ],
    );
  }

  /// Deletes the test. One that students have written takes their results with it, so it asks again.
  Future<void> _delete() async {
    final title = _title.text.trim().isEmpty ? 'this test' : '"${_title.text.trim()}"';
    final ok = await confirmCard(
      context,
      title: 'Delete $title?',
      body: _attempts > 0
          ? 'Students have written it. Their results for it will be deleted too, for good.'
          : "It will be removed from Tests and from students' lists.",
      confirm: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await api.delete('/teacher/tests/${widget.id}${_attempts > 0 ? '?with_results=1' : ''}');
      if (mounted) context.go('/t');
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }
}

/// One setting as a row: its name small above its value, with a chevron when a tap changes it.
class _SettingRow extends StatelessWidget {
  const _SettingRow({this.label, required this.value, this.onTap});
  final String? label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final shown = Fig(value, style: rowTitleStyle.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600), maxLines: 3);
    return RowTile(
      titleWidget: label == null ? shown : Fig(label!, style: labelStyle.copyWith(fontSize: 11.5, fontWeight: FontWeight.w600)),
      metaWidget: label == null ? null : shown,
      chevron: onTap != null,
      onTap: onTap,
    );
  }
}

/// A time to finish as a pill: 38 high so it is easy to hit, one line.
class _TimeChip extends StatelessWidget {
  const _TimeChip(this.label, {required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        label: label,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: selected
              ? BoxDecoration(color: actionFill, borderRadius: BorderRadius.circular(rPill), boxShadow: e2)
              : surface(radius: rPill, shadow: e1),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: chipStyle.copyWith(fontSize: 13.5, fontWeight: FontWeight.w600, color: selected ? actionInk : ink)),
          ]),
        ),
      );
}

/// A setting that is on or off, as a row with a switch.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label, required this.on, required this.onChanged});
  final String label;
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: () => onChanged(!on),
        label: '$label, ${on ? 'on' : 'off'}',
        child: Container(
          padding: const EdgeInsets.fromLTRB(17, 14, 15, 14),
          decoration: surface(radius: rCard, shadow: e1),
          child: Row(children: [
            Expanded(child: Fig(label, style: rowTitleStyle.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600), maxLines: 3)),
            const SizedBox(width: 12),
            AnimatedContainer( // motion: approved
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              width: 46,
              height: 28,
              padding: const EdgeInsets.all(3),
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(color: on ? success : faint, borderRadius: BorderRadius.circular(999)),
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: Color(0x2E000000), blurRadius: 3, offset: Offset(0, 1))],
                ),
              ),
            ),
          ]),
        ),
      );
}

/// Who writes the test: all of the group, or some of them picked from a list. Pops with the choice.
class _AudienceScreen extends StatefulWidget {
  const _AudienceScreen({required this.group, required this.audience, required this.ids});
  final List<Map<String, dynamic>> group;
  final String audience;
  final Set<String> ids;

  @override
  State<_AudienceScreen> createState() => _AudienceScreenState();
}

class _AudienceScreenState extends State<_AudienceScreen> {
  late String _audience = widget.audience;
  late final Set<String> _ids = {...widget.ids};

  int get _chosen => widget.group.where((s) => _ids.contains(s['id'])).length;

  @override
  Widget build(BuildContext context) {
    final n = widget.group.length;
    final some = _audience == 'students';
    final stuck = some && _chosen == 0;
    return PushedPanel(
      title: 'Who writes it',
      footer: PrimaryButton(
        'Done',
        onTap: stuck ? null : () => Navigator.of(context).pop((audience: _audience, ids: _ids)),
        disabledReason: stuck ? 'Choose at least one student.' : null,
      ),
      children: [
        const SizedBox(height: 18),
        RowTile(
          leading: Tick(on: !some),
          title: n == 1 ? 'The 1 student in the group' : 'All $n students',
          onTap: () => setState(() => _audience = 'group'),
        ),
        const SizedBox(height: 8),
        RowTile(
          leading: Tick(on: some),
          title: 'Some of them',
          meta: some ? '$_chosen chosen' : null,
          onTap: () => setState(() => _audience = 'students'),
        ),
        if (some) ...[
          SectionRule('Students', count: n, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
          for (final (i, s) in widget.group.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            RowTile(
              leading: Tick(on: _ids.contains('${s['id']}')),
              title: '${s['display_name']}',
              onTap: () => setState(() {
                final id = '${s['id']}';
                _ids.contains(id) ? _ids.remove(id) : _ids.add(id);
              }),
            ),
          ],
        ],
      ],
    );
  }
}

/// Completion ring used as a checkbox: idle ring, or filled with a tick.
class Tick extends StatelessWidget {
  const Tick({super.key, required this.on});
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

/// The questions a test can use: a group's (its class and subject), or a course's own.
class QuestionPicker extends StatefulWidget {
  const QuestionPicker({super.key, this.classLevel, this.subjectId, this.subjectName = '', this.courseId, this.courseName, required this.selected});
  final int? classLevel;
  final String? subjectId;
  final String subjectName;
  final String? courseId;
  final String? courseName;
  final List<Map<String, dynamic>> selected;

  /// What the questions belong to, for the headings: "10th Maths" or the course's name.
  String get title => courseId != null ? (courseName ?? 'Course') : groupName(classLevel!, subjectName);

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
      final r = await api.get(widget.courseId != null
          ? '/teacher/questions?course=${widget.courseId}'
          : '/teacher/questions?class=${widget.classLevel}&subject=${widget.subjectId}');
      // The ready-made library is not offered anywhere in the app.
      final all = (r['questions'] as List).cast<Map<String, dynamic>>();
      if (mounted) setState(() => _all = [for (final x in all) if (x['source'] != 'library') x]);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  bool _has(Map<String, dynamic> q) => _picked.any((p) => p['id'] == q['id']);

  @override
  Widget build(BuildContext context) {
    final all = _all;
    // Chapters in book order (the API sorts questions by chapter), with how many each has.
    final chapterCounts = <String, int>{};
    for (final q in all ?? const <Map<String, dynamic>>[]) {
      if (q['chapter'] != null) chapterCounts.update('${q['chapter']}', (n) => n + 1, ifAbsent: () => 1);
    }
    final shown = all?.where((q) => _chapter == null || q['chapter'] == _chapter).toList();
    final notPicked = shown?.where((q) => !_has(q)).toList() ?? const [];
    return PushedPanel(
      kicker: widget.title,
      title: 'Choose questions',
      footer: PrimaryButton(
        _picked.isEmpty ? 'Choose questions' : 'Use ${_picked.length} question${_picked.length == 1 ? '' : 's'}',
        onTap: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked),
        disabledReason: 'Tap questions to add them to the test.',
      ),
      children: [
        const SizedBox(height: 18),
        if (chapterCounts.isNotEmpty)
          FilterBar(padding: EdgeInsets.zero, children: [
            SelectPill(
              label: _chapter ?? 'All chapters',
              active: _chapter != null,
              onTap: () async {
                final c = await showChoices<String>(
                  context,
                  title: 'Chapter',
                  subtitle: widget.title,
                  options: [const Choice(null, 'All chapters'), for (final e in chapterCounts.entries) Choice(e.key, e.key, count: e.value)],
                  selected: _chapter,
                );
                if (c != null) setState(() => _chapter = c.value);
              },
            ),
          ]),
        if (notPicked.isNotEmpty && _chapter != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction('Add all ${notPicked.length} from this chapter', color: ink, onTap: () => setState(() => _picked.addAll(notPicked))),
          ),
        const SizedBox(height: 14),
        if (all == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (all == null)
          const LoadingState()
        else if (shown!.isEmpty)
          widget.courseId != null
              ? const EmptyState(icon: Ph.books, title: 'No questions in this course yet', body: 'Upload a paper or describe a test to AI first. Its questions are kept in the course.')
              : EmptyState(icon: Ph.books, title: 'No ${widget.title} questions', body: 'Add some in Questions or from a question paper first.')
        else
          for (final (i, q) in shown.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            RowTile(
              leading: Tick(on: _has(q)),
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

class _TestResultsScreenState extends State<TestResultsScreen> with WidgetsBindingObserver, AutoRefresh<TestResultsScreen> {
  @override
  Set<Area> get refreshAreas => {Area.tests};

  @override
  Future<void> refreshQuietly() => _load();

  @override
  Duration? get pollEvery => const Duration(seconds: 30);

  Map<String, dynamic>? _d;
  String? _error;
  bool _allQuestions = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    markLoaded();
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
      title: published ? 'Take this test down?' : 'Post this test?',
      body: published
          ? 'Students will no longer see it. Results already written are kept.'
          : (_d?['test']?['course_id'] != null ? 'The people in the course will see it.' : 'Students in the class will see it.'),
      confirm: published ? 'Take it down' : 'Post it',
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
      ['Name', 'Class', 'Status', 'Marks', 'Out of', 'Percent', 'Minutes taken', 'Handed in at'].map(cell).join(','),
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
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(rows: 3),
      ]);
    }
    final t = Map<String, dynamic>.from(d['test']);
    final sum = Map<String, dynamic>.from(d['summary']);
    final students = (d['students'] as List).cast<Map<String, dynamic>>();
    final questions = (d['questions'] as List).cast<Map<String, dynamic>>();
    final published = t['status'] == 'published';
    final closes = f.parseTime(t['closes_at']);
    final opens = f.parseTime(t['opens_at']);
    final isCourse = t['course_id'] != null;
    final cls = isCourse
        ? '${t['course'] ?? 'Course'}'
        : t['subject'] == null
            ? className(t['class_level'])
            : groupName(t['class_level'] as int, '${t['subject']}');
    // The closing time is long now that it names its day and date, so it takes a line of its own.
    final kicker = !published
        ? '$cls · not posted'
        : closes == null
            ? cls
            : '$cls\n${closes.isAfter(DateTime.now()) ? 'closes' : 'closed'} ${f.whenDate(closes)}';

    return PushedPanel(
      onRefresh: _load,
      kicker: kicker,
      kickerLines: 2,
      title: '${t['title']}',
      headerTrailing: CircleBtn(icon: Ph.pencilSimple, label: 'Edit test', onTap: () async {
        await context.push('/t/tests/${widget.id}/edit');
        _load();
      }),
      footer: Row(children: [
        Expanded(child: SecondaryButton('Export', icon: Ph.export, onTap: students.isEmpty ? null : () => _export(t, students))),
        const SizedBox(width: 10),
        Expanded(child: SecondaryButton(published ? 'Take down' : 'Post', icon: published ? Ph.eyeSlash : Ph.eye, onTap: () => _togglePublish(published))),
      ]),
      children: [
        const SizedBox(height: 22),
        StatGrid(
          label: 'Average',
          value: sum['average_pct'] == null ? '-' : f.percent(sum['average_pct'] as num),
          note: sum['high_pct'] == null ? 'No one has handed it in yet' : 'High ${f.percent(sum['high_pct'] as num)} · low ${f.percent(sum['low_pct'] as num)}',
          small: [
            StatSmall('Handed in', '${sum['submitted']}/${sum['assigned']}'),
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
              'submitted' => 'Handed in ${f.when(f.parseTime(s['submitted_at'])!)} · ${f.duration(s['time_taken_sec'] as int)}'
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
        // The questions come last, two at a time. Tapping one opens it, to fix its answer: every
        // student who has written the test is marked again.
        SectionRule('Questions', count: questions.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        for (final (i, q) in (_allQuestions ? questions : questions.take(2).toList()).indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          _QuestionStatRow(
            q: q,
            onTap: () async {
              await context.push('/t/questions/${q['id']}');
              _load();
            },
          ),
        ],
        if (questions.length > 2)
          Center(
            child: TextAction(
              _allQuestions ? 'Show fewer questions' : 'Show all ${questions.length} questions',
              onTap: () => setState(() => _allQuestions = !_allQuestions),
            ),
          ),
        // The settings are last: what the tutor came for is who has written it and how it went.
        SectionRule('Settings', padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        FactList([
          ('Time limit', t['time_limit_min'] == null ? 'No limit' : '${t['time_limit_min']} min'),
          ('Opens', opens == null ? 'As soon as it was posted' : f.whenTitle(opens)),
          ('Closes', closes == null ? 'No closing time' : f.whenTitle(closes)),
          ('Order', t['shuffle'] == true ? 'Shuffled for each student' : 'Same for everyone'),
        ]),
      ],
    );
  }
}

class _QuestionStatRow extends StatelessWidget {
  const _QuestionStatRow({required this.q, this.onTap});
  final Map<String, dynamic> q;
  final VoidCallback? onTap;

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
      onTap: onTap,
    );
  }
}
