import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';
import 'common.dart';
import 'subjects.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver, AutoRefresh<SettingsScreen> {
  @override
  Set<Area> get refreshAreas => {Area.settings};

  @override
  Future<void> refreshQuietly() => _load();

  Map<String, dynamic>? _s;
  List<Map<String, dynamic>> _chapters = [];
  List<Map<String, dynamic>> _subjectRows = [];
  List<Subject> _subjects = [];
  int _chapterClass = 9;
  String? _chapterSubject;
  String? _error;
  final _tuition = TextEditingController();
  final _name = TextEditingController();
  final _current = TextEditingController();
  final _next = TextEditingController();
  String? _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_tuition, _name, _current, _next]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    markLoaded();
    try {
      final s = await api.get('/teacher/settings');
      final subjects = await api.get('/teacher/subjects');
      _s = Map<String, dynamic>.from(s);
      _subjectRows = (subjects['subjects'] as List).cast<Map<String, dynamic>>();
      _subjects = [for (final r in _subjectRows) Subject.fromJson(r)];
      if (!_subjects.any((x) => x.id == _chapterSubject)) {
        _chapterSubject = _subjects.where((x) => x.isDefault).map((x) => x.id).firstOrNull ?? _subjects.firstOrNull?.id;
      }
      _tuition.text = '${_s!['tuition_name']}';
      _name.text = '${_s!['me']['display_name']}';
      await _loadChapters();
      if (mounted) setState(() => _error = null);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// "9th Science" for the chapter list being shown.
  String? get _chapterGroup {
    for (final x in _subjects) {
      if (x.id == _chapterSubject) return groupName(_chapterClass, x.name);
    }
    return null;
  }

  Future<void> _loadChapters() async {
    final r = await api.get('/teacher/chapters?class=$_chapterClass${_chapterSubject == null ? '' : '&subject=$_chapterSubject'}');
    if (mounted) setState(() => _chapters = (r['chapters'] as List).cast<Map<String, dynamic>>());
  }

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) setState(() => _notice = done);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<String?> _ask(String title, String placeholder, {String initial = '', String action = 'Save'}) {
    final c = TextEditingController(text: initial);
    return showCentredCard<String>(
      context,
      title: title,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupedInputs(children: [
          BareField(controller: c, placeholder: placeholder, autofocus: true, capitalization: TextCapitalization.words, onSubmitted: (v) => Navigator.of(ctx).pop(v)),
        ]),
        const SizedBox(height: 16),
        PrimaryButton(action, onTap: () => Navigator.of(ctx).pop(c.text)),
      ]),
    );
  }

  Future<void> _editRow(String kind, Map<String, dynamic> row) async {
    // Maths is the main subject: it can be renamed but never deleted.
    final canDelete = row['is_default'] != true;
    final choice = await showCentredCard<String>(
      context,
      title: '${row['name']}',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SecondaryButton('Rename', icon: Ph.pencilSimple, onTap: () => Navigator.of(ctx).pop('rename')),
        if (canDelete) ...[
          const SizedBox(height: 10),
          SecondaryButton('Delete', icon: Ph.trash, tint: danger, onTap: () => Navigator.of(ctx).pop('delete')),
        ],
      ]),
    );
    if (choice == 'rename') {
      final name = await _ask('Rename', kind == 'subjects' ? 'Subject name' : 'Chapter name',
          initial: '${row['name']}');
      if (name != null && name.trim().isNotEmpty) {
        await _run(() => api.patch('/teacher/$kind/${row['id']}', {'name': name.trim()}), 'Renamed.');
        _load();
      }
    } else if (choice == 'delete' && mounted) {
      final ok = await confirmCard(
        context,
        title: 'Delete ${row['name']}?',
        body: switch (kind) {
          'subjects' => 'Students who take it are taken out of its groups. A subject with chapters, questions or tests cannot be deleted.',
          _ => 'Questions in this chapter stay in the bank without a chapter.',
        },
        confirm: 'Delete',
        destructive: true,
      );
      if (ok) {
        await _run(() => api.delete('/teacher/$kind/${row['id']}'), 'Deleted.');
        _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    if (s == null) {
      return PushedPanel(title: 'Settings', children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    final sample = Map<String, dynamic>.from(s['sample']);
    final ai = Map<String, dynamic>.from(s['ai']);
    final hasSample = sample.values.any((v) => (v as int) > 0);
    const rule = EdgeInsets.fromLTRB(0, 26, 0, 11);

    return PushedPanel(
      kicker: 'Teacher',
      title: 'Settings',
      children: [
        if (_notice != null) ...[const SizedBox(height: 16), InlineNotice(_notice!, tone: Tone.success, icon: Ph.checkCircle)],
        const SectionRule('Tuition', padding: rule),
        GroupedInputs(children: [
          NamedField(name: 'Tuition', controller: _tuition, placeholder: 'Tuition name', capitalization: TextCapitalization.words),
          NamedField(name: 'Your name', controller: _name, placeholder: 'As students see it', capitalization: TextCapitalization.words),
        ]),
        const SizedBox(height: 10),
        SecondaryButton('Save names', onTap: () => _run(() async {
              await api.patch('/teacher/settings', {'tuition_name': _tuition.text.trim(), 'display_name': _name.text.trim()});
              await session.restore();
            }, 'Names saved.')),
        SectionRule('Subjects', count: _subjectRows.length, padding: rule),
        for (final (i, sj) in _subjectRows.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          RowTile(
            title: '${sj['name']}',
            meta: '${sj['students']} students · ${sj['questions']} questions',
            chevron: true,
            onTap: () => _editRow('subjects', sj),
          ),
        ],
        const SizedBox(height: gapRow),
        SecondaryButton('Add subject', icon: Ph.plus, onTap: () async {
          final name = await _ask('Add a subject', 'Subject name', action: 'Add');
          if (name != null && name.trim().isNotEmpty) {
            await _run(() => api.post('/teacher/subjects', {'name': name.trim()}), 'Subject added.');
            _load();
          }
        }),
        const SectionRule('Chapters', padding: rule),
        FilterBar(padding: EdgeInsets.zero, children: [
          ClassFilter(value: _chapterClass, allowAll: false, onChanged: (c) {
            setState(() => _chapterClass = c ?? 9);
            _loadChapters();
          }),
          if (_subjects.length > 1)
            SubjectFilter(subjects: _subjects, value: _chapterSubject, allowAll: false, onChanged: (v) {
              setState(() => _chapterSubject = v);
              _loadChapters();
            }),
        ]),
        const SizedBox(height: 10),
        for (final (i, ch) in _chapters.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          RowTile(title: '${ch['name']}', meta: '${ch['questions']} questions', chevron: true, onTap: () => _editRow('chapters', ch)),
        ],
        const SizedBox(height: gapRow),
        SecondaryButton('Add a ${_chapterGroup ?? 'Class $_chapterClass'} chapter', icon: Ph.plus, onTap: () async {
          final name = await _ask('Add a chapter', 'Chapter name', action: 'Add');
          if (name != null && name.trim().isNotEmpty) {
            await _run(
              () => api.post('/teacher/chapters', {'class_level': _chapterClass, 'subject_id': _chapterSubject, 'name': name.trim()}),
              'Chapter added.',
            );
            _loadChapters();
          }
        }),
        const SectionRule('Theme', padding: rule),
        ListenableBuilder(
          listenable: session,
          builder: (context, _) => Wrap(spacing: 8, children: [
            for (final (t, label) in [(ThemeChoice.system, 'Same as phone'), (ThemeChoice.light, 'Light'), (ThemeChoice.dark, 'Dark')])
              SegChip(label, selected: session.theme == t, onTap: () => session.setTheme(t)),
          ]),
        ),
        const SectionRule('Password', padding: rule),
        GroupedInputs(children: [
          BareField(controller: _current, placeholder: 'Current password', obscure: true),
          BareField(controller: _next, placeholder: 'New password, 8 or more characters', obscure: true),
        ]),
        const SizedBox(height: 10),
        SecondaryButton('Change password', icon: Ph.key, onTap: () => _run(() async {
              await api.post('/teacher/password', {'current': _current.text, 'next': _next.text});
              _current.clear();
              _next.clear();
            }, 'Password changed.')),
        const SectionRule('App', padding: rule),
        const AppVersionPanel(),
        const SectionRule('AI paper reader', padding: rule),
        FactList([('Pages read today', '${ai['calls_today']}'), ('Failed today', '${ai['failed_today']}')]),
        // Only the dev branch has sample data; the live app never shows this section.
        if (hasSample) ...[
          const SectionRule('Sample data', padding: rule),
          FactList([
            ('Sample students', '${sample['users']}'),
            ('Sample questions', '${sample['questions']}'),
            ('Sample tests', '${sample['tests']}'),
          ]),
          const SizedBox(height: 10),
          SecondaryButton('Delete all sample data', icon: Ph.trash, tint: danger, onTap: () async {
            final ok = await confirmCard(
              context,
              title: 'Delete all sample data?',
              body: 'The sample students, their results, the sample questions and the sample tests are removed. Your own students, questions and tests are kept. This cannot be undone.',
              confirm: 'Delete',
              destructive: true,
            );
            if (ok) {
              await _run(() => api.delete('/teacher/sample-data'), 'Sample data deleted.');
              _load();
            }
          }),
        ],
        const SizedBox(height: 34),
        SecondaryButton('Log out', icon: Ph.signOut, tint: danger, onTap: () async {
          final ok = await confirmCard(context, title: 'Log out?', body: 'You will need your username and password to log back in.', confirm: 'Log out', destructive: true);
          if (ok) session.logout();
        }),
      ],
    );
  }
}
