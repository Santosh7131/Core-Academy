import 'dart:math';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';
import 'subjects.dart';

// ---------------------------------------------------------------- list

class StudentsScreen extends StatefulWidget {
  const StudentsScreen({super.key});

  @override
  State<StudentsScreen> createState() => _StudentsScreenState();
}

class _StudentsScreenState extends State<StudentsScreen> {
  List<Map<String, dynamic>>? _rows;
  List<Subject> _subjects = [];
  String? _error;
  int? _class;
  String? _subject;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/teacher/students');
      final subjects = await loadSubjects();
      if (mounted) {
        setState(() {
          _rows = (r['students'] as List).cast<Map<String, dynamic>>();
          _subjects = subjects;
          if (!subjects.any((x) => x.id == _subject)) _subject = null;
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

  static bool _studies(Map<String, dynamic> s, String subjectId) =>
      (s['subjects'] as List? ?? const []).any((x) => (x as Map)['id'] == subjectId);

  @override
  Widget build(BuildContext context) {
    final all = _rows;
    final inClass = all?.where((s) => _class == null || s['class_level'] == _class).toList();
    final rows = inClass?.where((s) => _subject == null || _studies(s, _subject!)).toList();
    final active = all?.where((s) => s['active'] == true).length ?? 0;
    String? subjectName;
    for (final x in _subjects) {
      if (x.id == _subject) subjectName = x.name;
    }
    // A class and a subject together are a group, e.g. "9th Science".
    final group = _class != null && subjectName != null ? groupName(_class!, subjectName) : null;
    return SafeArea(
      bottom: false,
      child: ListView(padding: EdgeInsets.zero, children: [
        TabHeader(
          kicker: all == null ? 'Students' : (group != null ? '$group · ${rows!.length}' : '$active active'),
          title: 'Students',
          actions: [CircleBtn(icon: Ph.userPlus, filled: true, label: 'Add student', onTap: () => _open('/t/students/new'))],
        ),
        const SizedBox(height: 18),
        ClassChips(value: _class, allowAll: true, onChanged: (c) => setState(() => _class = c)),
        if (_subjects.length > 1) ...[
          const SizedBox(height: 8),
          SubjectChips(
            subjects: _subjects,
            value: _subject,
            allowAll: true,
            counts: inClass == null ? null : {for (final x in _subjects) x.id: inClass.where((s) => _studies(s, x.id)).length},
            onChanged: (v) => setState(() => _subject = v),
          ),
        ],
        const SizedBox(height: 16),
        if (all == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (all == null)
          const LoadingState()
        else if (rows!.isEmpty)
          EmptyState(
            icon: Ph.users,
            title: all.isEmpty
                ? 'No students yet'
                : group != null
                    ? 'No students in $group'
                    : _class != null
                        ? 'No students in Class $_class'
                        : 'No students take $subjectName',
            body: group != null
                ? 'Open a Class $_class student and add $subjectName to put them in this group.'
                : 'Add a student to create their username and PIN.',
            action: SizedBox(width: 200, child: PrimaryButton('Add a student', onTap: () => _open('/t/students/new'))),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Column(children: [
              for (final (i, s) in rows.indexed) ...[
                if (i > 0) const SizedBox(height: gapRow),
                RowTile(
                  leading: AppAvatar(name: '${s['display_name']}', seed: '${s['id']}'),
                  title: '${s['display_name']}',
                  meta: [
                    'Class ${s['class_level']}',
                    if (subjectNames(s['subjects']).isNotEmpty) subjectNames(s['subjects']).join(', '),
                    if (s['school'] != null) '${s['school']}',
                    if (s['active'] != true) 'login off',
                  ].join(' · '),
                  trailing: s['avg_pct'] == null
                      ? Text('-', style: numStyle(size: 15, color: faint))
                      : Text(f.percent(s['avg_pct'] as num), style: numStyle(size: 15, color: s['active'] == true ? ink : faint)),
                  onTap: () => _open('/t/students/${s['id']}'),
                ),
              ],
            ]),
          ),
        navClearance,
      ]),
    );
  }
}

// ---------------------------------------------------------------- add

class AddStudentScreen extends StatefulWidget {
  const AddStudentScreen({super.key});

  @override
  State<AddStudentScreen> createState() => _AddStudentScreenState();
}

class _AddStudentScreenState extends State<AddStudentScreen> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  bool _usernameEdited = false;
  int? _class;
  String? _schoolId;
  List<Map<String, dynamic>> _schools = [];
  List<Subject> _subjects = [];
  Set<String> _subjectIds = {};
  String _pin = _randomPin();
  bool _busy = false;

  static String _randomPin() => Random.secure().nextInt(10000).toString().padLeft(4, '0');

  @override
  void initState() {
    super.initState();
    _loadSchools();
    _loadSubjects();
  }

  Future<void> _loadSubjects() async {
    try {
      final subjects = await loadSubjects();
      if (mounted) {
        setState(() {
          _subjects = subjects;
          // Most students take maths.
          _subjectIds = {for (final x in subjects) if (x.isDefault) x.id};
        });
      }
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _loadSchools() async {
    try {
      final r = await api.get('/teacher/schools');
      if (mounted) {
        setState(() {
          _schools = (r['schools'] as List).cast<Map<String, dynamic>>();
          if (_schools.length == 1) _schoolId = '${_schools.first['id']}';
        });
      }
    } on ApiException {
      // Schools are optional here.
    }
  }

  /// "Harini Venkatesh" -> "harini.v"
  void _suggest(String name) {
    if (_usernameEdited) return;
    final parts = name.toLowerCase().replaceAll(RegExp(r'[^a-z\s]'), '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final s = parts.isEmpty ? '' : (parts.length == 1 ? parts.first : '${parts.first}.${parts.last[0]}');
    _username.text = s;
    setState(() {});
  }

  Future<void> _addSchool() async {
    final c = TextEditingController();
    final name = await showCentredCard<String>(
      context,
      title: 'Add a school',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupedInputs(children: [
          BareField(controller: c, placeholder: 'School name', autofocus: true, capitalization: TextCapitalization.words, onSubmitted: (v) => Navigator.of(ctx).pop(v)),
        ]),
        const SizedBox(height: 16),
        PrimaryButton('Add', onTap: () => Navigator.of(ctx).pop(c.text)),
      ]),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      final r = await api.post('/teacher/schools', {'name': name.trim()});
      await _loadSchools();
      setState(() => _schoolId = '${r['school']['id']}');
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  String? get _missing {
    if (_name.text.trim().isEmpty) return 'Type the student\'s name.';
    if (_class == null) return 'Choose a class.';
    if (_subjectIds.isEmpty) return 'Choose at least one subject.';
    if (!RegExp(r'^[a-z0-9._]{3,24}$').hasMatch(_username.text.trim())) return 'Usernames need 3 to 24 lowercase letters, numbers or dots.';
    return null;
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final r = await api.post('/teacher/students', {
        'display_name': _name.text.trim(),
        'class_level': _class,
        'school_id': _schoolId,
        'username': _username.text.trim(),
        'pin': _pin,
        'subject_ids': _subjectIds.toList(),
      });
      if (!mounted) return;
      final login = r['login'] as Map<String, dynamic>;
      await showLoginCard(context, name: _name.text.trim(), username: '${login['username']}', pin: '${login['pin']}');
      if (mounted) context.pop();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final missing = _missing;
    return PushedPanel(
      kicker: 'New student',
      title: 'Add student',
      footer: PrimaryButton(
        _busy ? 'Creating login' : 'Create login',
        onTap: missing == null && !_busy ? _create : null,
        disabledReason: _busy ? null : missing,
      ),
      children: [
        const SizedBox(height: 22),
        GroupedInputs(children: [
          BareField(
            controller: _name,
            placeholder: 'Full name',
            capitalization: TextCapitalization.words,
            action: TextInputAction.done,
            onChanged: _suggest,
          ),
        ]),
        const FormLabel('Class'),
        ClassChips(value: _class, padding: EdgeInsets.zero, onChanged: (c) => setState(() => _class = c)),
        const FormLabel('Subjects'),
        SubjectToggles(subjects: _subjects, value: _subjectIds, onChanged: (v) => setState(() => _subjectIds = v)),
        if (_class != null && _subjectIds.isNotEmpty) ...[
          const SizedBox(height: 10),
          Fig('Joins ${[for (final x in _subjects) if (_subjectIds.contains(x.id)) groupName(_class!, x.name)].join(' and ')}.', style: labelStyle),
        ],
        const FormLabel('School'),
        ChipRow(padding: EdgeInsets.zero, children: [
          for (final s in _schools) SegChip('${s['name']}', selected: _schoolId == s['id'], onTap: () => setState(() => _schoolId = '${s['id']}')),
          SegChip('Add school', selected: false, onTap: _addSchool),
        ]),
        const FormLabel('Login'),
        GroupedInputs(children: [
          BareField(
            controller: _username,
            placeholder: 'Username',
            keyboard: TextInputType.visiblePassword,
            onChanged: (_) => setState(() => _usernameEdited = true),
          ),
        ]),
        const SizedBox(height: 10),
        Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 12, 10, 12),
          child: Row(children: [
            Text('PIN', style: bodyStyle.copyWith(color: muted)),
            const Spacer(),
            Text(_pin, style: numStyle(size: 22, weight: FontWeight.w600).copyWith(letterSpacing: 5)),
            const SizedBox(width: 10),
            CircleBtn(icon: Ph.arrowsClockwise, label: 'New PIN', ground: fill, onTap: () => setState(() => _pin = _randomPin())),
          ]),
        ),
        const SizedBox(height: 10),
        Fig('After creating the login you can share the username and PIN on WhatsApp.', style: labelStyle),
      ],
    );
  }
}

// ---------------------------------------------------------------- detail

class StudentDetailScreen extends StatefulWidget {
  const StudentDetailScreen({super.key, required this.id});
  final String id;

  @override
  State<StudentDetailScreen> createState() => _StudentDetailScreenState();
}

class _StudentDetailScreenState extends State<StudentDetailScreen> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.get('/teacher/students/${widget.id}');
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

  Future<void> _resetPin(Map<String, dynamic> s) async {
    final ok = await confirmCard(
      context,
      title: 'Reset the PIN?',
      body: '${s['display_name']} will be logged out and will need the new PIN.',
      confirm: 'Reset PIN',
    );
    if (!ok) return;
    try {
      final r = await api.post('/teacher/students/${widget.id}/reset-pin', {});
      if (!mounted) return;
      await showLoginCard(context, name: '${s['display_name']}', username: '${r['login']['username']}', pin: '${r['login']['pin']}');
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _editSubjects(Map<String, dynamic> s) async {
    final List<Subject> subjects;
    try {
      subjects = await loadSubjects();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
      return;
    }
    if (!mounted) return;
    var chosen = {for (final x in (s['subjects'] as List? ?? const [])) '${(x as Map)['id']}'};
    final result = await showCentredCard<Set<String>>(
      context,
      title: 'Subjects',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setCard) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Fig('${s['display_name']} gets the tests of each group they are in.', style: bodyStyle.copyWith(color: muted)),
          const SizedBox(height: 14),
          SubjectToggles(subjects: subjects, value: chosen, onChanged: (v) => setCard(() => chosen = v)),
          const SizedBox(height: 18),
          PrimaryButton(
            'Save',
            onTap: chosen.isEmpty ? null : () => Navigator.of(ctx).pop(chosen),
            disabledReason: chosen.isEmpty ? 'Choose at least one subject.' : null,
          ),
        ]),
      ),
    );
    if (result == null) return;
    try {
      await api.patch('/teacher/students/${widget.id}', {'subject_ids': result.toList()});
      _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> s) async {
    final active = s['active'] == true;
    final ok = await confirmCard(
      context,
      title: active ? 'Turn off this login?' : 'Turn this login back on?',
      body: active
          ? '${s['display_name']} will be logged out and cannot log in until you turn it back on. Their results are kept.'
          : '${s['display_name']} will be able to log in again with the same PIN.',
      confirm: active ? 'Turn off' : 'Turn on',
      destructive: active,
    );
    if (!ok) return;
    try {
      await api.post('/teacher/students/${widget.id}/active', {'active': !active});
      _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return PushedPanel(title: 'Student', children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    final s = Map<String, dynamic>.from(d['student']);
    final attempts = (d['attempts'] as List).cast<Map<String, dynamic>>();
    final done = attempts.where((a) => a['submitted_at'] != null).toList();
    final chapters = (d['chapters'] as List).cast<Map<String, dynamic>>();
    final missed = (d['missed'] as List).cast<Map<String, dynamic>>();
    final avg = done.isEmpty
        ? null
        : done.map((a) => (a['score'] as num) / max((a['max_score'] as num), 1)).reduce((x, y) => x + y) / done.length;
    final lastSeen = f.parseTime(s['last_seen_at']);

    return PushedPanel(
      kicker: ['Class ${s['class_level']}', if (s['school'] != null) '${s['school']}', if (s['active'] != true) 'login off'].join(' · '),
      title: '${s['display_name']}',
      children: [
        const SizedBox(height: 22),
        MeasurementCard(
          label: 'Average marks',
          value: avg == null ? '-' : '${(avg * 100).round()}',
          unit: avg == null ? null : '%',
          fraction: avg,
          note: '${done.length} tests written · ${missed.length} missed'
              '${lastSeen == null ? '' : ' · last seen ${f.relative(lastSeen)}'}',
        ),
        if (chapters.isNotEmpty) ...[
          const SectionRule('By chapter', padding: EdgeInsets.fromLTRB(0, 26, 0, 11)),
          Surface(
            shadow: e1,
            padding: const EdgeInsets.fromLTRB(17, 6, 17, 6),
            child: Column(children: [
              for (final c in chapters)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(children: [
                    Expanded(flex: 5, child: Text('${c['chapter']}', style: rowTitleStyle, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 12),
                    Expanded(flex: 4, child: Track((c['correct'] as int) / max(c['total'] as int, 1), height: 6)),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 46,
                      child: Text(f.percent((c['correct'] as int) / max(c['total'] as int, 1)), style: numStyle(size: 13), textAlign: TextAlign.right),
                    ),
                  ]),
                ),
            ]),
          ),
        ],
        SectionRule('Groups', count: subjectNames(s['subjects']).length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        if (subjectNames(s['subjects']).isNotEmpty) ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final n in subjectNames(s['subjects'])) TagChip(groupName(s['class_level'] as int, n)),
          ]),
          const SizedBox(height: 12),
        ],
        SecondaryButton('Change subjects', icon: Ph.pencilSimple, onTap: () => _editSubjects(s)),
        SectionRule('Tests', count: attempts.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
        if (attempts.isEmpty)
          Text('No tests written yet.', style: bodyStyle.copyWith(color: muted))
        else
          for (final (i, a) in attempts.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              title: '${a['title']}${(a['attempt_no'] as int) > 1 ? ' (retake)' : ''}',
              meta: a['submitted_at'] == null
                  ? 'Writing now'
                  : 'Submitted ${f.when(f.parseTime(a['submitted_at'])!)}'
                      ' · ${f.duration(f.parseTime(a['submitted_at'])!.difference(f.parseTime(a['started_at'])!).inSeconds)}',
              trailing: a['submitted_at'] == null
                  ? const TagChip('Writing', tone: Tone.warning)
                  : Text('${f.marks(a['score'])}/${f.marks(a['max_score'])}', style: numStyle(size: 15)),
              onTap: a['submitted_at'] == null ? null : () => context.push('/t/attempts/${a['id']}'),
            ),
          ],
        if (missed.isNotEmpty) ...[
          SectionRule('Missed', count: missed.length, alert: true, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
          for (final (i, m) in missed.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(title: '${m['title']}', meta: 'Closed ${f.when(f.parseTime(m['closes_at'])!)}'),
          ],
        ],
        const SectionRule('Login', padding: EdgeInsets.fromLTRB(0, 26, 0, 11)),
        FactList([('Username', '${s['username']}')]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: SecondaryButton('Reset PIN', icon: Ph.key, onTap: () => _resetPin(s))),
          const SizedBox(width: 10),
          Expanded(
            child: SecondaryButton(
              s['active'] == true ? 'Turn off login' : 'Turn on login',
              icon: s['active'] == true ? Ph.prohibit : Ph.checkCircle,
              tint: s['active'] == true ? danger : null,
              onTap: () => _toggleActive(s),
            ),
          ),
        ]),
      ],
    );
  }
}
