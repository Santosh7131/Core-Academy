import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/tokens.dart';
import '../../ui/update_card.dart';
import 'common.dart';
import 'subjects.dart';
import 'tests_screens.dart' show testState;

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String _enc(String s) => Uri.encodeComponent(s);

/// The page of one group, e.g. 10th Maths.
String groupPath(Map<String, dynamic> g) => '/t/groups/${g['class_level']}/${g['subject_id']}?name=${_enc('${g['subject']}')}';

// ---------------------------------------------------------------- home

/// The tutor's home: every group, with the tests students can write now (live) and the tests
/// posted for later, and how many students have submitted or are writing.
class TutorHome extends StatefulWidget {
  const TutorHome({super.key});

  @override
  State<TutorHome> createState() => _TutorHomeState();
}

class _TutorHomeState extends State<TutorHome> with WidgetsBindingObserver, AutoRefresh<TutorHome> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  Set<Area> get refreshAreas => {Area.tests, Area.students, Area.papers};

  // Students start and submit tests all the time: check every 30 s while this is on screen.
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
      final d = await api.get('/teacher/home');
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

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Kicker('${session.tuitionName} · ${DateFormat('d MMMM').format(DateTime.now())}'),
                  const SizedBox(height: 6),
                  Text('Home', style: displayStyle),
                ]),
              ),
              RefreshButton(onRefresh: _load),
              const SizedBox(width: 10),
              Pressable(
                label: 'Settings',
                onTap: () => context.push('/t/settings'),
                child: AppAvatar(name: '${session.user?['display_name'] ?? ''}', seed: '${session.user?['id'] ?? ''}', size: 40),
              ),
            ]),
          ),
          const UpdateBanner(),
          if (d == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (d == null)
            const LoadingState()
          else
            ..._body(d),
          navClearance,
        ]),
      ),
    );
  }

  List<Widget> _body(Map<String, dynamic> d) {
    final groups = (d['groups'] as List).cast<Map<String, dynamic>>();
    final totals = Map<String, dynamic>.from(d['totals']);
    final live = _n(totals['live']);
    final writing = _n(totals['writing']);
    final posted = groups.fold<int>(0, (s, g) => s + (g['posted'] as List).length);
    bool has(Map<String, dynamic> g, String k) => (g[k] as List).isNotEmpty;
    // Groups with something running come first (live before posted-only). The rest fold into one short list
    // so a tutor with a dozen groups still sees what matters without scrolling past empty cards.
    final busy = [
      ...groups.where((g) => has(g, 'live')),
      ...groups.where((g) => !has(g, 'live') && has(g, 'posted')),
    ];
    final quiet = groups.where((g) => !has(g, 'live') && !has(g, 'posted')).toList();
    final summary = [
      live == 0 ? 'No test is live right now' : '${f.count(live, 'test')} live now · ${f.count(writing, 'student')} writing',
      if (posted > 0) '$posted posted',
    ].join(' · ');
    return [
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 0), child: InlineNotice(_error!, icon: Ph.warning)),
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 14, gutter, 18),
        child: Fig(summary, style: bodyStyle.copyWith(color: muted)),
      ),
      if (groups.isEmpty)
        const EmptyState(icon: Ph.users, title: 'No groups yet', body: 'Open Groups and add your first student. Each class and subject becomes a group.')
      else ...[
        if (busy.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Surface(
              shadow: e1,
              padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
              child: Fig('Nothing is live or posted. Open a group below to make a test.', style: bodyStyle.copyWith(color: muted)),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Column(children: [
              for (final (i, g) in busy.indexed) ...[if (i > 0) const SizedBox(height: gapRow), _GroupCard(g: g)],
            ]),
          ),
        if (quiet.isNotEmpty) ...[
          SectionRule(busy.isEmpty ? 'Your groups' : 'No test running', count: quiet.length),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Surface(
              shadow: e1,
              padding: const EdgeInsets.symmetric(horizontal: 17),
              child: Column(children: [
                for (final (i, g) in quiet.indexed) ...[
                  if (i > 0) Container(height: 1, color: hairline),
                  _QuietGroup(g: g),
                ],
              ]),
            ),
          ),
        ],
      ],
    ];
  }
}

/// One line for a group with nothing live or posted: name and student count, tap to open it.
class _QuietGroup extends StatelessWidget {
  const _QuietGroup({required this.g});
  final Map<String, dynamic> g;

  @override
  Widget build(BuildContext context) {
    final name = groupName(g['class_level'] as int, '${g['subject']}');
    return Pressable(
      label: 'Open $name',
      onTap: () => context.push(groupPath(g)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(children: [
          Expanded(child: Fig(name, style: rowTitleStyle, maxLines: 1)),
          const SizedBox(width: 12),
          Fig(f.count(_n(g['students']), 'student'), style: labelStyle),
          const SizedBox(width: 8),
          Icon(Ph.caretRight, size: 16, color: faint),
        ]),
      ),
    );
  }
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.g});
  final Map<String, dynamic> g;

  @override
  Widget build(BuildContext context) {
    final name = groupName(g['class_level'] as int, '${g['subject']}');
    final live = (g['live'] as List).cast<Map<String, dynamic>>();
    final posted = (g['posted'] as List).cast<Map<String, dynamic>>();

    Widget block(String label, Tone tone, List<Map<String, dynamic>> tests, {required bool isLive}) =>
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const SizedBox(height: 14),
          Align(alignment: Alignment.centerLeft, child: TagChip(label, tone: tone)),
          for (final t in tests) ...[
            Container(height: 1, margin: const EdgeInsets.only(top: 8), color: hairline),
            _MiniTest(t: t, live: isLive),
          ],
        ]);

    return Surface(
      shadow: e1,
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Pressable(
          label: 'Open $name',
          onTap: () => context.push(groupPath(g)),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Fig(name, style: titleStyle.copyWith(fontSize: 20, letterSpacing: -0.6), maxLines: 1),
                const SizedBox(height: 3),
                Fig(f.count(_n(g['students']), 'student'), style: labelStyle),
              ]),
            ),
            Icon(Ph.caretRight, size: 18, color: faint),
          ]),
        ),
        if (live.isNotEmpty) block('Live now', Tone.success, live, isLive: true),
        if (posted.isNotEmpty) block('Posted', Tone.neutral, posted, isLive: false),
      ]),
    );
  }
}

class _MiniTest extends StatelessWidget {
  const _MiniTest({required this.t, required this.live});
  final Map<String, dynamic> t;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final closes = f.parseTime(t['closes_at']);
    final opens = f.parseTime(t['opens_at']);
    final writing = _n(t['writing']);
    final meta = live
        ? (closes == null ? 'Open' : 'Closes ${f.when(closes)}')
        : (opens == null ? 'Posted' : 'Opens ${f.when(opens)}${closes == null ? '' : ' · closes ${f.when(closes)}'}');
    return Pressable(
      label: '${t['title']}',
      onTap: () => context.push('/t/tests/${t['id']}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 11),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Fig('${t['title']}', style: rowTitleStyle, maxLines: 1),
              const SizedBox(height: 2),
              Fig(meta, style: labelStyle, maxLines: 1),
            ]),
          ),
          const SizedBox(width: 12),
          if (live)
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${_n(t['submitted'])}/${_n(t['assigned'])}', style: numStyle(size: 15)),
              const SizedBox(height: 2),
              Fig(writing > 0 ? '$writing writing now' : 'submitted', style: labelStyle.copyWith(color: writing > 0 ? warning : null)),
            ])
          else
            Fig(f.count(_n(t['assigned']), 'student'), style: labelStyle),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- groups

class GroupsScreen extends StatefulWidget {
  const GroupsScreen({super.key});

  @override
  State<GroupsScreen> createState() => _GroupsScreenState();
}

class _GroupsScreenState extends State<GroupsScreen> with WidgetsBindingObserver, AutoRefresh<GroupsScreen> {
  List<Map<String, dynamic>>? _groups;
  String? _error;

  @override
  Set<Area> get refreshAreas => {Area.tests, Area.students};

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
      final d = await api.get('/teacher/home');
      if (mounted) {
        setState(() {
          _groups = (d['groups'] as List).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _newGroup() async {
    List<Subject> subjects;
    try {
      subjects = await loadSubjects();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
      return;
    }
    if (!mounted) return;
    int? cls;
    String? subjectId;
    final ok = await showCentredCard<bool>(
      context,
      title: 'New group',
      subtitle: 'A group is a class and a subject, like 10th Maths.',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const FormLabel('Class', top: 4),
          ClassField(value: cls, onChanged: (c) => set(() => cls = c)),
          const FormLabel('Subject'),
          SubjectField(subjects: subjects, value: subjectId, onChanged: (v) => set(() => subjectId = v)),
          const SizedBox(height: 18),
          PrimaryButton(
            'Open the group',
            onTap: cls == null || subjectId == null ? null : () => Navigator.of(ctx).pop(true),
            disabledReason: cls == null || subjectId == null ? 'Choose a class and a subject.' : null,
          ),
        ]),
      ),
    );
    if (ok != true || cls == null || subjectId == null || !mounted) return;
    final name = subjects.firstWhere((x) => x.id == subjectId).name;
    await context.push('/t/groups/$cls/$subjectId?name=${_enc(name)}');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          TabHeader(kicker: groups == null ? 'Your classes' : f.count(groups.length, 'group'), title: 'Groups'),
          const SizedBox(height: 18),
          if (groups == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (groups == null)
            const LoadingState()
          else ...[
            if (groups.isEmpty)
              const EmptyState(icon: Ph.users, title: 'No groups yet', body: 'Tap New group, choose a class and a subject, then add the first student.')
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: gutter),
                child: Column(children: [
                  for (final (i, g) in groups.indexed) ...[
                    if (i > 0) const SizedBox(height: gapRow),
                    Builder(builder: (context) {
                      final live = (g['live'] as List).length;
                      final posted = (g['posted'] as List).length;
                      return RowTile(
                        title: groupName(g['class_level'] as int, '${g['subject']}'),
                        meta: [f.count(_n(g['students']), 'student'), if (posted > 0) '$posted posted'].join(' · '),
                        trailing: live > 0 ? TagChip('$live live', tone: Tone.success) : null,
                        chevron: true,
                        onTap: () async {
                          await context.push(groupPath(g));
                          _load();
                        },
                      );
                    }),
                  ],
                ]),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
              child: SecondaryButton('New group', icon: Ph.plus, onTap: _newGroup),
            ),
          ],
          navClearance,
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- one group

class GroupScreen extends StatefulWidget {
  const GroupScreen({super.key, required this.classLevel, required this.subjectId, required this.subjectName});
  final int classLevel;
  final String subjectId;
  final String subjectName;

  @override
  State<GroupScreen> createState() => _GroupScreenState();
}

class _GroupScreenState extends State<GroupScreen> with WidgetsBindingObserver, AutoRefresh<GroupScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _allFinished = false;

  String get _name => groupName(widget.classLevel, widget.subjectName);

  @override
  Set<Area> get refreshAreas => {Area.tests, Area.students, Area.papers};

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
      final d = await api.get('/teacher/groups/${widget.classLevel}/${widget.subjectId}');
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

  String get _query => 'class=${widget.classLevel}&subject=${widget.subjectId}&name=${_enc(widget.subjectName)}';

  Future<void> _makeTest() async {
    final ready = (_d?['ready_made'] as List?)?.length ?? 0;
    final choice = await showCentredCard<String>(
      context,
      title: 'Make a test',
      subtitle: 'For $_name',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        RowTile(
          leading: Icon(Ph.fileArrowUp, size: 22, color: ink),
          title: 'Upload a PDF or photos',
          meta: 'AI reads the questions and finds the answers',
          chevron: true,
          onTap: () => Navigator.of(ctx).pop('upload'),
        ),
        const SizedBox(height: 10),
        RowTile(
          leading: Icon(Ph.scan, size: 22, color: aiAccentInk),
          title: 'Describe it to AI',
          meta: 'Say what you want and AI writes the questions',
          chevron: true,
          onTap: () => Navigator.of(ctx).pop('chat'),
        ),
        if (ready > 0) ...[
          const SizedBox(height: 10),
          RowTile(
            leading: Icon(Ph.books, size: 22, color: ink),
            title: 'Use a ready-made test',
            meta: '${f.count(ready, 'chapter test')} waiting',
            chevron: true,
            onTap: () => Navigator.of(ctx).pop('ready'),
          ),
        ],
      ]),
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case 'upload':
        _go('/t/papers/new?$_query');
      case 'chat':
        _go('/t/groups/${widget.classLevel}/${widget.subjectId}/chat?name=${_enc(widget.subjectName)}');
      case 'ready':
        _go('/t/groups/${widget.classLevel}/${widget.subjectId}/ready?name=${_enc(widget.subjectName)}');
    }
  }

  String _meta(Map<String, dynamic> t) {
    final closes = f.parseTime(t['closes_at']);
    final opens = f.parseTime(t['opens_at']);
    final q = f.count(_n(t['question_count']), 'question');
    return switch (testState(t)) {
      'open' => '$q · ${closes == null ? 'open' : 'closes ${f.when(closes)}'}',
      'upcoming' => '$q · opens ${opens == null ? 'later' : f.when(opens)}',
      'closed' => '$q · closed ${closes == null ? '' : f.when(closes)}',
      _ => '$q · not posted yet',
    };
  }

  Widget _tile(Map<String, dynamic> t) {
    final published = t['status'] == 'published';
    final writing = _n(t['writing']);
    return RowTile(
      title: '${t['title']}',
      meta: _meta(t),
      trailing: !published
          ? const TagChip('Draft')
          : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('${_n(t['submitted'])}/${_n(t['assigned'])}', style: numStyle(size: 15)),
              const SizedBox(height: 2),
              Fig(writing > 0 ? '$writing writing' : 'submitted', style: labelStyle.copyWith(color: writing > 0 ? warning : null)),
            ]),
      onTap: () => _go(published ? '/t/tests/${t['id']}' : '/t/tests/${t['id']}/edit'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return PushedPanel(
      kicker: 'Group',
      title: _name,
      children: [
        if (d == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (d == null)
          const LoadingState()
        else
          ..._body(d),
      ],
    );
  }

  List<Widget> _body(Map<String, dynamic> d) {
    const rule = EdgeInsets.fromLTRB(0, 28, 0, 11);
    final students = (d['students'] as List).cast<Map<String, dynamic>>();
    final tests = (d['tests'] as List).cast<Map<String, dynamic>>();
    List<Map<String, dynamic>> of(String s) => tests.where((t) => testState(t) == s).toList();
    final live = of('open');
    final posted = of('upcoming');
    final finished = of('closed');
    final drafts = of('draft');

    Widget rows(List<Map<String, dynamic>> list) => Column(children: [
          for (final (i, t) in list.indexed) ...[if (i > 0) const SizedBox(height: gapRow), _tile(t)],
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
        Padding(padding: const EdgeInsets.only(top: 22), child: Fig('No tests yet. Tap Make a test to start.', style: bodyStyle.copyWith(color: muted))),
      SectionRule('Students', count: students.length, padding: rule),
      if (students.isEmpty) Fig('No students in this group yet.', style: bodyStyle.copyWith(color: muted)),
      for (final (i, s) in students.indexed) ...[
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
          onTap: () => _go('/t/students/${s['id']}'),
        ),
      ],
      const SizedBox(height: gapRow),
      SecondaryButton('Add student', icon: Ph.userPlus, onTap: () => _go('/t/students/new?$_query')),
    ];
  }
}

// ---------------------------------------------------------------- AI chat

/// Describe the test you want and AI writes it. The questions open in the same review screen as an
/// uploaded paper, with their answers marked where two other AI models agree.
class ChatTestScreen extends StatefulWidget {
  const ChatTestScreen({super.key, required this.classLevel, required this.subjectId, required this.subjectName});
  final int classLevel;
  final String subjectId;
  final String subjectName;

  @override
  State<ChatTestScreen> createState() => _ChatTestScreenState();
}

class _ChatTestScreenState extends State<ChatTestScreen> {
  final _text = TextEditingController();
  int _count = 15;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _ready => _text.text.trim().length >= 5;

  Future<void> _write() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await api.post(
        '/teacher/papers/chat',
        {'class_level': widget.classLevel, 'subject_id': widget.subjectId, 'request': _text.text.trim(), 'count': _count},
        const Duration(minutes: 2),
      );
      if (mounted) context.pushReplacement('/t/papers/${r['paper']['id']}?read=1');
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PushedPanel(
        kicker: groupName(widget.classLevel, widget.subjectName),
        title: 'Describe your test',
        footer: PrimaryButton(
          _busy ? 'Writing the questions' : 'Write the questions',
          leadingIcon: _busy ? null : Ph.scan,
          onTap: _ready && !_busy ? _write : null,
          disabledReason: _busy || _ready ? null : 'Say what the test should cover.',
        ),
        children: [
          const SizedBox(height: 14),
          Fig(
            'Say what the test should cover, as you would tell a colleague. For example: easy and medium questions on '
            'quadratic equations, with a few word problems.',
            style: bodyStyle.copyWith(color: muted),
          ),
          const FormLabel('Your request'),
          GroupedInputs(children: [
            BareField(
              controller: _text,
              placeholder: 'What should the test cover?',
              maxLines: null,
              minLines: 4,
              capitalization: TextCapitalization.sentences,
            ),
          ]),
          const FormLabel('How many questions'),
          SelectField(
            value: '$_count questions',
            onTap: _busy
                ? null
                : () async {
                    final c = await showChoices<int>(
                      context,
                      title: 'How many questions',
                      options: [for (final n in [10, 15, 20, 25, 30, 40]) Choice(n, '$n questions')],
                      selected: _count,
                    );
                    if (c?.value != null) setState(() => _count = c!.value!);
                  },
          ),
          if (_error != null) ...[const SizedBox(height: 16), InlineNotice(_error!, tone: Tone.danger, icon: Ph.warning)],
          if (_busy) ...[
            const SizedBox(height: 16),
            InlineNotice('AI is writing the questions. This takes about half a minute.', tone: Tone.ai, icon: Ph.scan),
          ],
          const SizedBox(height: 16),
          Fig(
            'After writing, two other AI models solve every question on their own. If their answers differ from each other or '
            'from the writer\'s, the question is left for you to mark.',
            style: labelStyle,
          ),
        ],
      );
}

// ---------------------------------------------------------------- ready-made tests

class ReadyTestsScreen extends StatefulWidget {
  const ReadyTestsScreen({super.key, required this.classLevel, required this.subjectId, required this.subjectName});
  final int classLevel;
  final String subjectId;
  final String subjectName;

  @override
  State<ReadyTestsScreen> createState() => _ReadyTestsScreenState();
}

class _ReadyTestsScreenState extends State<ReadyTestsScreen> {
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.get('/teacher/groups/${widget.classLevel}/${widget.subjectId}');
      if (mounted) setState(() => _rows = (d['ready_made'] as List).cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return PushedPanel(
      kicker: groupName(widget.classLevel, widget.subjectName),
      title: 'Ready-made tests',
      children: [
        const SizedBox(height: 14),
        Fig('One test for each chapter. Open one, choose when it closes, and post it.', style: bodyStyle.copyWith(color: muted)),
        const SizedBox(height: 18),
        if (rows == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (rows == null)
          const LoadingState()
        else if (rows.isEmpty)
          Fig('Every ready-made test for this group has been posted.', style: bodyStyle.copyWith(color: muted))
        else
          for (final (i, t) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              title: '${t['title']}',
              meta: f.count(_n(t['question_count']), 'question'),
              chevron: true,
              onTap: () async {
                await context.push('/t/tests/${t['id']}/edit');
                if (mounted) _load();
              },
            ),
          ],
      ],
    );
  }
}
