import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
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
  Map<String, dynamic> _tu = {};
  List<Map<String, dynamic>> _subjectRows = [];
  List<Map<String, dynamic>> _tutors = [];
  String? _meId;
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
      final tutors = await api.get('/teacher/tutors');
      _tu = Map<String, dynamic>.from((await api.get('/teacher/tuition'))['tuition']);
      _tutors = (tutors['tutors'] as List).cast<Map<String, dynamic>>();
      _meId = '${tutors['me']}';
      _s = Map<String, dynamic>.from(s);
      _subjectRows = (subjects['subjects'] as List).cast<Map<String, dynamic>>();
      _tuition.text = '${_s!['tuition_name']}';
      _name.text = '${_s!['me']['display_name']}';
      if (mounted) setState(() => _error = null);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
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

  /// Another tutor of this tuition: they log in with a username and password, and see every group.
  Future<void> _addTutor() async {
    final name = TextEditingController();
    final user = TextEditingController();
    final pass = TextEditingController();
    final ok = await showCentredCard<bool>(
      context,
      title: 'Add a tutor',
      subtitle: 'They log in with these, and see every group and student.',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupedInputs(children: [
          BareField(controller: name, placeholder: 'Name', capitalization: TextCapitalization.words),
          BareField(controller: user, placeholder: 'Username, in lowercase letters'),
          BareField(controller: pass, placeholder: 'Password, 8 or more characters', obscure: true),
        ]),
        const SizedBox(height: 16),
        PrimaryButton('Add tutor', onTap: () => Navigator.of(ctx).pop(true)),
      ]),
    );
    final body = {'display_name': name.text.trim(), 'username': user.text.trim().toLowerCase(), 'password': pass.text};
    for (final c in [name, user, pass]) {
      c.dispose();
    }
    if (ok != true) return;
    await _run(() => api.post('/teacher/tutors', body), 'Tutor added. Give them the username and the password.');
    _load();
  }

  Future<void> _toggleTutor(Map<String, dynamic> t) async {
    final on = t['active'] == true;
    final ok = await confirmCard(
      context,
      title: on ? 'Turn off ${t['display_name']}?' : 'Turn on ${t['display_name']}?',
      body: on ? 'They are signed out and cannot log in until you turn them on again.' : 'They can log in again.',
      confirm: on ? 'Turn off' : 'Turn on',
      destructive: on,
    );
    if (!ok) return;
    await _run(() => api.post('/teacher/tutors/${t['id']}/active', {'active': !on}), on ? 'Turned off.' : 'Turned on.');
    _load();
  }

  Future<void> _addSubject() async {
    try {
      final added = await addSubject(context);
      if (added != null) {
        if (mounted) setState(() => _notice = '${added.name} added.');
        _load();
      }
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  /// A new join code: the old one stops working at once.
  Future<void> _newCode() async {
    final ok = await confirmCard(
      context,
      title: 'Make a new join code?',
      body: 'The old code stops working. Students who are already in stay in.',
      confirm: 'New code',
    );
    if (!ok) return;
    await _run(() => api.post('/teacher/tuition/join-code'), 'New join code made.');
    _load();
  }

  Future<void> _editSubject(Map<String, dynamic> row) async {
    // A standard subject keeps its name; Maths is the first tuition's main subject and is never deleted.
    final canDelete = row['is_default'] != true;
    final canRename = row['standard'] != true;
    final choice = await showCentredCard<String>(
      context,
      title: '${row['name']}',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (canRename) SecondaryButton('Rename', icon: Ph.pencilSimple, onTap: () => Navigator.of(ctx).pop('rename')),
        if (canDelete) ...[
          if (canRename) const SizedBox(height: 10),
          SecondaryButton('Remove', icon: Ph.trash, tint: danger, onTap: () => Navigator.of(ctx).pop('delete')),
        ],
        if (!canRename && !canDelete) Fig('This is the main subject, so it stays.', style: bodyStyle.copyWith(color: muted)),
      ]),
    );
    if (choice == 'rename') {
      final name = await _ask('Rename', 'Subject name', initial: '${row['name']}');
      if (name != null && name.trim().isNotEmpty) {
        await _run(() => api.patch('/teacher/subjects/${row['id']}', {'name': name.trim()}), 'Renamed.');
        _load();
      }
    } else if (choice == 'delete' && mounted) {
      final ok = await confirmCard(
        context,
        title: 'Remove ${row['name']}?',
        body: 'Students who take it are taken out of its groups. A subject that already has tests, papers or questions cannot be removed.',
        confirm: 'Remove',
        destructive: true,
      );
      if (ok) {
        await _run(() => api.delete('/teacher/subjects/${row['id']}'), 'Removed.');
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
    final hasSample = sample.values.any((v) => (v as int) > 0);
    const rule = EdgeInsets.fromLTRB(0, 26, 0, 11);

    return PushedPanel(
      onRefresh: _load,
      kicker: 'Tutor',
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
              await session.refreshTuitions();
            }, 'Names saved.')),
        const SectionRule('Students joining', padding: rule),
        RowTile(
          title: 'Join code',
          meta: _tu['join_open'] == false ? 'Joining is closed' : null,
          trailing: Text('${_tu['join_code_shown'] ?? ''}', style: numStyle(size: 16, weight: FontWeight.w700).copyWith(letterSpacing: 2)),
          chevron: true,
          onTap: () => context.push('/t/code'),
        ),
        const SizedBox(height: gapRow),
        RowTile(
          title: 'Join requests',
          meta: (int.tryParse('${_tu['pending']}') ?? 0) == 0 ? 'None waiting' : '${_tu['pending']} waiting',
          chevron: true,
          onTap: () => context.push('/t/requests'),
        ),
        const SizedBox(height: 12),
        SegmentedToggle(
          labels: const ['Joining open', 'Joining closed'],
          index: _tu['join_open'] == false ? 1 : 0,
          onChanged: (i) => _run(() => api.patch('/teacher/tuition', {'join_open': i == 0}), i == 0 ? 'Students can ask to join.' : 'Nobody can ask to join now.').then((_) => _load()),
        ),
        if (_tu['role'] == 'owner') ...[
          const SizedBox(height: 12),
          SecondaryButton('New join code', icon: Ph.arrowsClockwise, onTap: _newCode),
        ],
        SectionRule('Tutors', count: _tutors.length, padding: rule),
        for (final (i, t) in _tutors.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          RowTile(
            leading: AppAvatar(name: '${t['display_name']}', seed: '${t['id']}'),
            title: '${t['display_name']}${t['id'] == _meId ? ' (you)' : ''}',
            meta: '${t['username']}${t['active'] == true ? '' : ' · turned off'}',
            trailing: t['id'] == _meId ? null : TextAction(t['active'] == true ? 'Turn off' : 'Turn on', onTap: () => _toggleTutor(t)),
          ),
        ],
        const SizedBox(height: gapRow),
        SecondaryButton('Add tutor', icon: Ph.userPlus, onTap: _addTutor),
        SectionRule('Subjects', count: _subjectRows.length, padding: rule),
        for (final (i, sj) in _subjectRows.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          RowTile(
            title: '${sj['name']}',
            meta: f.count(int.tryParse('${sj['students']}') ?? 0, 'student'),
            chevron: true,
            onTap: () => _editSubject(sj),
          ),
        ],
        const SizedBox(height: gapRow),
        SecondaryButton('Add subject', icon: Ph.plus, onTap: _addSubject),
        const SectionRule('Theme', padding: rule),
        ListenableBuilder(
          listenable: session,
          builder: (context, _) => SegmentedToggle(
            labels: const ['Phone', 'Light', 'Dark'],
            index: ThemeChoice.values.indexOf(session.theme),
            onChanged: (i) => session.setTheme(ThemeChoice.values[i]),
          ),
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
