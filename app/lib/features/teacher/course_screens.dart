import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/tokens.dart';
import 'common.dart';
import 'students_screens.dart' show randomPin, usernameGuess;
import 'tests_screens.dart' show TestListTile, Tick, testState;

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String _enc(String s) => Uri.encodeComponent(s);

/// The page of one course. The name rides along so the page has its title before it has loaded.
String coursePath(Map<String, dynamic> c) => '/t/courses/${c['id']}?name=${_enc('${c['name']}')}';

// ---------------------------------------------------------------- new course

/// Asks for a name and makes the course. Returns it ({id, name, ...}), or null when the tutor backed out.
Future<Map<String, dynamic>?> newCourse(BuildContext context) => showCentredCard<Map<String, dynamic>>(
      context,
      title: 'New course',
      subtitle: 'Name it so your people know it',
      builder: (ctx) => const _NewCourseCard(),
    );

class _NewCourseCard extends StatefulWidget {
  const _NewCourseCard();

  @override
  State<_NewCourseCard> createState() => _NewCourseCardState();
}

class _NewCourseCardState extends State<_NewCourseCard> {
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _ready => _name.text.trim().isNotEmpty;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.post('/teacher/courses', {'name': _name.text.trim()});
      if (mounted) Navigator.of(context).pop(Map<String, dynamic>.from(r['course'] as Map));
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Course name', style: labelStyle),
        const SizedBox(height: 8),
        GroupedInputs(children: [
          BareField(
            controller: _name,
            placeholder: 'e.g. Spoken English, Batch 1',
            autofocus: true,
            maxLength: 60,
            capitalization: TextCapitalization.words,
            action: TextInputAction.done,
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) {
              if (_ready && !_busy) _create();
            },
          ),
        ]),
        if (_error != null) ...[const SizedBox(height: 12), InlineNotice(_error!, tone: Tone.danger, icon: Ph.warning)],
        const SizedBox(height: 16),
        ListenableBuilder(
          listenable: _name,
          builder: (context, _) => PrimaryButton('Create course', busy: _busy, onTap: _ready ? _create : null),
        ),
      ]);
}

// ---------------------------------------------------------------- the tab

/// The Courses tab: every course of the tuition, with a way to start one.
class CoursesScreen extends StatefulWidget {
  const CoursesScreen({super.key});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> with WidgetsBindingObserver, AutoRefresh<CoursesScreen> {
  List<Map<String, dynamic>>? _courses;
  String? _error;

  @override
  Set<Area> get refreshAreas => {Area.courses, Area.tests, Area.students};

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    markLoaded();
    try {
      final d = await api.get('/teacher/courses');
      if (mounted) {
        setState(() {
          _courses = (d['courses'] as List).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// A new course opens at once, so the people can be added.
  Future<void> _new() async {
    final c = await newCourse(context);
    if (c == null || !mounted) return;
    await context.push(coursePath(c));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final courses = _courses;
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          TabHeader(
            kicker: courses == null || courses.isEmpty ? 'Your courses' : f.count(courses.length, 'course'),
            title: 'Courses',
            actions: [CircleBtn(icon: Ph.plus, label: 'New course', onTap: _new)],
          ),
          const SizedBox(height: 18),
          if (courses == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (courses == null)
            const LoadingState(inset: true, rows: 3)
          else if (courses.isEmpty)
            EmptyState(
              icon: Ph.graduationCap,
              title: 'No courses yet',
              body: 'A course is for people you teach apart from your groups. Create one, then add the people who join it.',
              action: PrimaryButton('Create a course', leadingIcon: Ph.plus, onTap: _new),
            )
          else
            ...staggered(
              [
                for (final (i, c) in courses.indexed) ...[
                  if (i > 0) const SizedBox(height: gapRow),
                  Padding(padding: const EdgeInsets.symmetric(horizontal: gutter), child: _CourseRow(course: c, onOpen: () => _open(c))),
                ],
              ],
              scope: this,
              prefix: 'course',
              stepMs: 50,
            ),
          navClearance,
        ]),
      ),
    );
  }

  Future<void> _open(Map<String, dynamic> c) async {
    await context.push(coursePath(c));
    if (mounted) _load();
  }
}

class _CourseRow extends StatelessWidget {
  const _CourseRow({required this.course, required this.onOpen});
  final Map<String, dynamic> course;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final live = (course['live'] as List? ?? const []).length;
    final posted = (course['posted'] as List? ?? const []).length;
    return RowTile(
      title: '${course['name']}',
      meta: [f.count(_n(course['people']), 'person', 'people'), if (posted > 0) '$posted posted'].join(' · '),
      trailing: live > 0 ? TagChip('$live live', tone: Tone.success) : null,
      chevron: true,
      onTap: onOpen,
    );
  }
}

// ---------------------------------------------------------------- one course

/// One course: its tests, like a group's page, and its people.
class CourseScreen extends StatefulWidget {
  const CourseScreen({super.key, required this.id, required this.name});
  final String id;
  final String name;

  @override
  State<CourseScreen> createState() => _CourseScreenState();
}

class _CourseScreenState extends State<CourseScreen> with WidgetsBindingObserver, AutoRefresh<CourseScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _allFinished = false;

  String get _name => _d == null ? widget.name : '${_d!['course']['name']}';

  @override
  Set<Area> get refreshAreas => {Area.courses, Area.tests, Area.students, Area.papers};

  // Students start and hand in tests all the time: check every 30 s while this is on screen.
  @override
  Duration? get pollEvery => const Duration(seconds: 30);

  @override
  Future<void> refreshQuietly() => _load(quiet: true);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool quiet = false}) async {
    markLoaded();
    try {
      final d = await api.get('/teacher/courses/${widget.id}');
      if (mounted) {
        setState(() {
          _d = Map<String, dynamic>.from(d);
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted && !quiet) setState(() => _error = e.message);
    }
  }

  Future<void> _go(String path) async {
    await context.push(path);
    if (mounted) _load();
  }

  Future<void> _makeTest() async {
    final choice = await showCentredCard<String>(
      context,
      title: 'Make a test',
      subtitle: 'For $_name',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        RowTile(
          leading: Icon(Ph.fileArrowUp, size: 22, color: ink),
          title: 'Upload a PDF or photos',
          meta: 'AI reads the questions',
          chevron: true,
          onTap: () => Navigator.of(ctx).pop('upload'),
        ),
        const SizedBox(height: 10),
        RowTile(
          leading: Icon(Ph.scan, size: 22, color: aiAccentInk),
          title: 'Describe it to AI',
          meta: 'AI writes the questions',
          chevron: true,
          onTap: () => Navigator.of(ctx).pop('chat'),
        ),
      ]),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'upload':
        _go('/t/papers/new?course=${widget.id}&name=${_enc(_name)}');
      case 'chat':
        _go('/t/courses/${widget.id}/chat?name=${_enc(_name)}');
    }
  }

  /// The course, its tests and everyone's results go; the people keep their logins and their groups.
  Future<void> _delete() async {
    final yes = await confirmCard(
      context,
      title: 'Delete this course?',
      body: 'This deletes $_name, its tests and everyone\'s results. The people in it keep their logins and their groups. This cannot be undone.',
      confirm: 'Delete course',
      destructive: true,
    );
    if (!yes || !mounted) return;
    try {
      await api.delete('/teacher/courses/${widget.id}?with_results=1');
      if (mounted) context.pop();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return PushedPanel(
      onRefresh: _load,
      kicker: 'Course',
      title: _name,
      children: [
        if (d == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (d == null)
          const LoadingState(rows: 3)
        else
          ...staggered(_body(d), scope: this, prefix: 'course', stepMs: 50),
      ],
    );
  }

  List<Widget> _body(Map<String, dynamic> d) {
    const rule = EdgeInsets.fromLTRB(0, 28, 0, 11);
    final people = (d['people'] as List).cast<Map<String, dynamic>>();
    final tests = (d['tests'] as List).cast<Map<String, dynamic>>();
    List<Map<String, dynamic>> of(String s) => tests.where((t) => testState(t) == s).toList();
    final live = of('open');
    final posted = of('upcoming');
    final finished = [...of('done'), ...of('closed')];
    final drafts = of('draft');

    Widget rows(List<Map<String, dynamic>> list) => Column(children: [
          for (final (i, t) in list.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            TestListTile(t: t, onTap: () => _go(t['status'] == 'published' ? '/t/tests/${t['id']}' : '/t/tests/${t['id']}/edit')),
          ],
        ]);

    return [
      const SizedBox(height: 18),
      PrimaryButton('Make a test', leadingIcon: Ph.plus, onTap: _makeTest),
      if (live.isNotEmpty) ...[SectionRule('Live now', count: live.length, padding: rule), rows(live)],
      if (posted.isNotEmpty) ...[SectionRule('Posted', count: posted.length, padding: rule), rows(posted)],
      if (drafts.isNotEmpty) ...[SectionRule('Drafts', count: drafts.length, padding: rule), rows(drafts)],
      if (finished.isNotEmpty) ...[
        SectionRule('Finished', count: finished.length, padding: rule),
        rows(_allFinished ? finished : finished.take(3).toList()),
        if (finished.length > 3)
          Center(child: TextAction(_allFinished ? 'Show fewer' : 'Show all ${finished.length} finished tests', onTap: () => setState(() => _allFinished = !_allFinished))),
      ],
      if (live.isEmpty && posted.isEmpty && finished.isEmpty && drafts.isEmpty)
        Padding(padding: const EdgeInsets.only(top: 22), child: Fig('No tests yet.', style: bodyStyle.copyWith(color: muted))),
      SectionRule('People', count: people.length, padding: rule),
      if (people.isEmpty) Fig('No one is in this course yet. Add the people who join it.', style: bodyStyle.copyWith(color: muted)),
      for (final (i, s) in people.indexed) ...[
        if (i > 0) const SizedBox(height: gapRow),
        RowTile(
          leading: AppAvatar(name: '${s['display_name']}', seed: '${s['id']}'),
          title: '${s['display_name']}',
          meta: s['active'] != true
              ? 'Login turned off'
              : _n(s['tests_done']) == 0
                  ? 'No tests written yet'
                  : '${f.count(_n(s['tests_done']), 'test')} written${s['avg_pct'] == null ? '' : ' · average ${f.percent(s['avg_pct'] as num)}'}',
          chevron: true,
          onTap: () => _go('/t/students/${s['id']}?course=${widget.id}&name=${_enc(_name)}'),
        ),
      ],
      const SizedBox(height: gapRow),
      SecondaryButton('Add people', icon: Ph.userPlus, onTap: () => _go('/t/courses/${widget.id}/add?name=${_enc(_name)}')),
      const SizedBox(height: 22),
      Center(child: TextAction('Delete this course', color: danger, onTap: _delete)),
    ];
  }
}

// ---------------------------------------------------------------- add people

/// Puts people in a course: students the tuition already has (from any class), or a new person who is only in
/// this course. Adding someone here never takes them out of their groups.
class AddPeopleScreen extends StatefulWidget {
  const AddPeopleScreen({super.key, required this.courseId, required this.courseName});
  final String courseId;
  final String courseName;

  @override
  State<AddPeopleScreen> createState() => _AddPeopleScreenState();
}

/// The groups a student is in as (key, label) pairs, e.g. ("10|subject-id", "10th Maths"). A person with no class has none.
List<(String, String)> _groupsOf(Map<String, dynamic> s) {
  final cls = (s['class_level'] as num?)?.toInt();
  if (cls == null) return const [];
  return [
    for (final x in (s['subjects'] as List? ?? const [])) ('$cls|${(x as Map)['id']}', groupName(cls, '${x['name']}')),
  ];
}

class _AddPeopleScreenState extends State<AddPeopleScreen> {
  int _tab = 0;

  // From your students
  List<Map<String, dynamic>>? _students;
  String? _error;
  final _search = TextEditingController();

  /// The group the list is narrowed to: null for everyone, 'none' for people who are in no group, else a group key.
  String? _group;
  final Set<String> _picked = {};
  bool _adding = false;

  // New person
  final _name = TextEditingController();
  final _username = TextEditingController();
  bool _usernameEdited = false;
  String _pin = randomPin();
  int _suggestSeq = 0;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    _username.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/teacher/students');
      if (mounted) {
        setState(() {
          _students = (r['students'] as List).cast<Map<String, dynamic>>().where((s) => s['active'] == true).toList();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  bool _inCourse(Map<String, dynamic> s) => (s['courses'] as List? ?? const []).any((c) => (c as Map)['id'] == widget.courseId);

  bool _matches(Map<String, dynamic> s) {
    final q = _search.text.trim().toLowerCase();
    if (q.isNotEmpty && !'${s['display_name']}'.toLowerCase().contains(q)) return false;
    return switch (_group) {
      null => true,
      'none' => s['class_level'] == null,
      final key => _groupsOf(s).any((g) => g.$1 == key),
    };
  }

  /// The groups the tuition's students are in, for the filter, with how many people each has.
  List<(String, String, int)> get _groups {
    final seen = <String, (String, int)>{};
    for (final s in _students ?? const <Map<String, dynamic>>[]) {
      for (final (key, label) in _groupsOf(s)) {
        seen[key] = (label, (seen[key]?.$2 ?? 0) + 1);
      }
    }
    final keys = seen.keys.toList()
      ..sort((a, b) {
        final x = a.split('|');
        final y = b.split('|');
        final byClass = int.parse(x[0]).compareTo(int.parse(y[0]));
        return byClass != 0 ? byClass : seen[a]!.$1.compareTo(seen[b]!.$1);
      });
    return [for (final k in keys) (k, seen[k]!.$1, seen[k]!.$2)];
  }

  String get _groupLabel {
    final g = _group;
    if (g == null) return 'All students';
    if (g == 'none') return 'In no group';
    return _groups.where((x) => x.$1 == g).map((x) => x.$2).firstOrNull ?? 'All students';
  }

  Future<void> _pickGroup() async {
    final noGroup = (_students ?? const <Map<String, dynamic>>[]).where((s) => s['class_level'] == null).length;
    final c = await showChoices<String>(
      context,
      title: 'Show',
      options: [
        Choice(null, 'All students', count: _students?.length),
        for (final (key, label, n) in _groups) Choice(key, label, count: n),
        if (noGroup > 0) Choice('none', 'In no group', count: noGroup),
      ],
      selected: _group,
    );
    if (c != null) setState(() => _group = c.value);
  }

  Future<void> _add() async {
    setState(() => _adding = true);
    try {
      await api.post('/teacher/courses/${widget.courseId}/people', {'student_ids': _picked.toList()});
      if (mounted) context.pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// The login to suggest for the name typed: a guess at once, then the server's word on what is free.
  void _suggest(String name) {
    if (_usernameEdited) return;
    _username.text = usernameGuess(name);
    setState(() {});
    final seq = ++_suggestSeq;
    if (name.trim().isEmpty) return;
    Future<void>.delayed(const Duration(milliseconds: 350), () async {
      if (!mounted || seq != _suggestSeq || _usernameEdited) return;
      try {
        final r = await api.get('/teacher/username-suggestion?name=${Uri.encodeQueryComponent(name.trim())}');
        if (mounted && seq == _suggestSeq && !_usernameEdited) setState(() => _username.text = '${r['username']}');
      } on ApiException {
        // Keep the guess made on the phone; the server also fixes a taken login when it is created.
      }
    });
  }

  String? get _missingNew {
    if (_name.text.trim().isEmpty) return 'Type the person\'s name.';
    if (!RegExp(r'^[a-z0-9._]{3,24}$').hasMatch(_username.text.trim())) return 'Usernames need 3 to 24 lowercase letters, numbers or dots.';
    return null;
  }

  Future<void> _create() async {
    setState(() => _creating = true);
    try {
      final r = await api.post('/teacher/courses/${widget.courseId}/people/new', {
        'display_name': _name.text.trim(),
        'username': _username.text.trim(),
        'pin': _pin,
      });
      if (!mounted) return;
      final login = r['login'] as Map<String, dynamic>;
      await showLoginCard(context, name: _name.text.trim(), username: '${login['username']}', pin: '${login['pin']}');
      if (mounted) context.pop(true);
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) => PushedPanel(
        kicker: widget.courseName,
        title: 'Add people',
        footer: _tab == 0 ? _existingFooter() : _newFooter(),
        children: [
          const SizedBox(height: 18),
          SegmentedToggle(labels: const ['From your students', 'New person'], index: _tab, onChanged: (i) => setState(() => _tab = i)),
          const SizedBox(height: 16),
          if (_tab == 0) ..._existing() else ..._newPerson(),
        ],
      );

  // ------------------------------------------------------------ from your students

  Widget _existingFooter() {
    final n = _picked.length;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PrimaryButton(
        n == 0 ? 'Add people' : 'Add ${f.count(n, 'person', 'people')}',
        busy: _adding,
        onTap: n == 0 ? null : _add,
        disabledReason: n == 0 && !_adding ? 'Tap the people to add.' : null,
      ),
      const SizedBox(height: 9),
      Fig('Adding people here does not take them out of their groups.', style: labelStyle, textAlign: TextAlign.center),
    ]);
  }

  List<Widget> _existing() {
    final all = _students;
    if (all == null) {
      return [if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(rows: 4)];
    }
    if (all.isEmpty) {
      return const [EmptyState(icon: Ph.users, title: 'No students yet', body: 'Add students in a group first, or make a new person here.')];
    }
    final shown = all.where(_matches).toList();
    final selectable = shown.where((s) => !_inCourse(s)).toList();
    final allPicked = selectable.isNotEmpty && selectable.every((s) => _picked.contains('${s['id']}'));
    return [
      GroupedInputs(children: [
        BareField(controller: _search, placeholder: 'Search by name', onChanged: (_) => setState(() {})),
      ]),
      const SizedBox(height: 12),
      Row(children: [
        Flexible(child: Align(alignment: Alignment.centerLeft, child: SelectPill(label: _groupLabel, active: _group != null, onTap: _pickGroup))),
        const SizedBox(width: 8),
        if (selectable.isNotEmpty)
          TextAction(
            allPicked ? 'Clear' : 'Select all ${selectable.length}',
            color: ink,
            onTap: () => setState(() {
              final ids = [for (final s in selectable) '${s['id']}'];
              allPicked ? _picked.removeAll(ids) : _picked.addAll(ids);
            }),
          ),
      ]),
      const SizedBox(height: 14),
      if (shown.isEmpty)
        Padding(padding: const EdgeInsets.only(top: 10), child: Fig('No one matches that.', style: bodyStyle.copyWith(color: muted))),
      for (final (i, s) in shown.indexed) ...[
        if (i > 0) const SizedBox(height: gapRow),
        _personRow(s),
      ],
    ];
  }

  Widget _personRow(Map<String, dynamic> s) {
    final id = '${s['id']}';
    final already = _inCourse(s);
    final groups = _groupsOf(s).map((g) => g.$2).join(', ');
    final row = RowTile(
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        Tick(on: already || _picked.contains(id)),
        const SizedBox(width: 12),
        AppAvatar(name: '${s['display_name']}', seed: id),
      ]),
      title: '${s['display_name']}',
      meta: groups.isEmpty ? (s['class_level'] == null ? 'In no group' : className(s['class_level'])) : groups,
      trailing: already ? const TagChip('In this course') : null,
      onTap: already ? null : () => setState(() => _picked.contains(id) ? _picked.remove(id) : _picked.add(id)),
    );
    return already ? Opacity(opacity: 0.6, child: row) : row;
  }

  // ------------------------------------------------------------ new person

  Widget _newFooter() {
    final missing = _missingNew;
    return PrimaryButton('Create login', busy: _creating, onTap: missing == null ? _create : null, disabledReason: _creating ? null : missing);
  }

  List<Widget> _newPerson() => [
        GroupedInputs(children: [
          BareField(
            controller: _name,
            placeholder: 'Full name',
            maxLength: 60,
            capitalization: TextCapitalization.words,
            action: TextInputAction.done,
            onChanged: _suggest,
          ),
        ]),
        const FormLabel('Login'),
        GroupedInputs(children: [
          BareField(
            controller: _username,
            placeholder: 'Username',
            maxLength: 24,
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
            CircleBtn(icon: Ph.arrowsClockwise, label: 'New PIN', ground: fill, onTap: () => setState(() => _pin = randomPin())),
          ]),
        ),
        const SizedBox(height: 16),
        InlineNotice('A new person is only in this course. They are not added to any group.', tone: Tone.neutral, icon: Ph.info),
      ];
}
