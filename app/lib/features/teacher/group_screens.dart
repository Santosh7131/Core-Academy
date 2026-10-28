import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';
import 'make_test.dart';
import 'subjects.dart';
import 'tests_screens.dart' show TestListTile, testState;

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

String _enc(String s) => Uri.encodeComponent(s);

/// The page of one group, e.g. 10th Maths.
String groupPath(Map<String, dynamic> g) => '/t/groups/${g['class_level']}/${g['subject_id']}?name=${_enc('${g['subject']}')}';

// ---------------------------------------------------------------- a new group

/// Starts a group: asks for its class and subject, makes it on the server and opens it, so its first students can be added.
/// The screen that asked loads its list again when this is over.
Future<void> startNewGroup(BuildContext context) async {
  List<Subject> subjects;
  try {
    subjects = await loadSubjects();
  } on ApiException catch (e) {
    if (context.mounted) showProblem(context, e);
    return;
  }
  if (!context.mounted) return;
  int? cls;
  String? subjectId;
  final ok = await showCentredCard<bool>(
    context,
    title: 'New group',
    subtitle: 'A class and a subject, like 10th Maths',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const FormLabel('Class', top: 4),
        ClassField(value: cls, onChanged: (c) => set(() => cls = c)),
        const FormLabel('Subject'),
        SubjectField(
          subjects: subjects,
          value: subjectId,
          onChanged: (v) => set(() => subjectId = v),
          onAdded: (s) => set(() {
            subjects.add(s);
            subjectId = s.id;
          }),
        ),
        const SizedBox(height: 18),
        PrimaryButton(
          'Open the group',
          onTap: cls == null || subjectId == null ? null : () => Navigator.of(ctx).pop(true),
          disabledReason: cls == null || subjectId == null ? 'Choose a class and a subject.' : null,
        ),
      ]),
    ),
  );
  if (ok != true || cls == null || subjectId == null || !context.mounted) return;
  final name = subjects.firstWhere((x) => x.id == subjectId).name;
  // The group exists from now on, even before its first student.
  try {
    await api.post('/teacher/groups', {'class_level': cls, 'subject_id': subjectId});
  } on ApiException catch (e) {
    if (context.mounted) showProblem(context, e);
    return;
  }
  if (!context.mounted) return;
  await context.push('/t/groups/$cls/$subjectId?name=${_enc(name)}');
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
    final target = TestTarget.group(classLevel: widget.classLevel, subjectId: widget.subjectId, subjectName: widget.subjectName);
    if (await makeTestFor(context, target) && mounted) _load();
  }

  /// Only an empty group can go (no students, no tests): the server refuses any other.
  Future<void> _remove() async {
    final yes = await confirmCard(
      context,
      title: 'Remove $_name?',
      body: 'It has no students or tests. You can add the group again later.',
      confirm: 'Remove',
      destructive: true,
    );
    if (!yes || !mounted) return;
    try {
      await api.delete('/teacher/groups/${widget.classLevel}/${widget.subjectId}');
      changes.reportAreas({Area.settings, Area.students, Area.tests});
      if (mounted) context.pop();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Widget _tile(Map<String, dynamic> t) => TestListTile(
        t: t,
        onTap: () => _go(t['status'] == 'published' ? '/t/tests/${t['id']}' : '/t/tests/${t['id']}/edit'),
      );

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return PushedPanel(
      onRefresh: _load,
      kicker: 'Group',
      title: _name,
      children: [
        if (d == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (d == null)
          const LoadingState(rows: 3)
        else
          ...staggered(_body(d), scope: this, prefix: 'group', stepMs: 50),
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
    final finished = [...of('done'), ...of('closed')];
    final drafts = of('draft');

    Widget rows(List<Map<String, dynamic>> list) => Column(children: [
          for (final (i, t) in list.indexed) ...[if (i > 0) const SizedBox(height: gapRow), _tile(t)],
        ]);

    return [
      const SizedBox(height: 18),
      PrimaryButton('Make a test', leadingIcon: Ph.plus, onTap: _makeTest),
      if (live.isNotEmpty) ...[SectionRule('Open now', count: live.length, padding: rule), rows(live)],
      if (posted.isNotEmpty) ...[SectionRule('Coming up', count: posted.length, padding: rule), rows(posted)],
      if (drafts.isNotEmpty) ...[SectionRule('Not posted yet', count: drafts.length, padding: rule), rows(drafts)],
      if (finished.isNotEmpty) ...[
        SectionRule('Finished', count: finished.length, padding: rule),
        rows(_allFinished ? finished : finished.take(3).toList()),
        if (finished.length > 3)
          Center(child: TextAction(_allFinished ? 'Show fewer' : 'Show all ${finished.length} finished tests', onTap: () => setState(() => _allFinished = !_allFinished))),
      ],
      if (live.isEmpty && posted.isEmpty && finished.isEmpty && drafts.isEmpty)
        Padding(padding: const EdgeInsets.only(top: 22), child: Fig('No tests yet.', style: bodyStyle.copyWith(color: muted))),
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
      if (students.isEmpty && tests.isEmpty) ...[
        const SizedBox(height: 22),
        Center(child: TextAction('Remove this group', color: danger, onTap: _remove)),
      ],
    ];
  }
}

// ---------------------------------------------------------------- AI chat

/// Describe the test you want and AI writes it. The questions open in the same review screen as an
/// uploaded paper, with their answers marked where two other AI models agree.
class ChatTestScreen extends StatefulWidget {
  /// For a group: its class and subject. For a course: [courseId], and [subjectName] holds the course's name.
  const ChatTestScreen({super.key, this.classLevel, this.subjectId, required this.subjectName, this.courseId});
  final int? classLevel;
  final String? subjectId;
  final String subjectName;
  final String? courseId;

  @override
  State<ChatTestScreen> createState() => _ChatTestScreenState();
}

class _ChatTestScreenState extends State<ChatTestScreen> {
  final _text = TextEditingController();
  final _countText = TextEditingController(text: '15');
  bool _busy = false;
  String? _error;

  /// How far a long test has got, and how long AI asks us to wait when it has used its limit.
  int _written = 0;
  int _wanted = 0;
  int _waitLeft = 0;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _countText.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    _countText.dispose();
    super.dispose();
  }

  /// Any number from 1 up to a thousand (the top only guards against a slip of the finger).
  int? get _count {
    final n = int.tryParse(_countText.text.trim());
    return n != null && n >= 1 && n <= 1000 ? n : null;
  }

  bool get _ready => _text.text.trim().length >= 5 && _count != null;

  /// One call to the writer, waiting out AI's per-minute limit when it says so.
  Future<Map<String, dynamic>> _ask(Map<String, dynamic> body) async {
    for (var waits = 0;; waits++) {
      try {
        return Map<String, dynamic>.from(await api.post('/teacher/papers/chat', body, const Duration(minutes: 2)));
      } on ApiException catch (e) {
        if (e.code != 'ai_busy' || waits >= 8 || !mounted) rethrow;
        final secs = (int.tryParse(RegExp(r'(\d+) second').firstMatch(e.message)?.group(1) ?? '') ?? 20).clamp(4, 60);
        for (var left = secs; left > 0 && mounted; left--) {
          setState(() => _waitLeft = left);
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        if (mounted) setState(() => _waitLeft = 0);
      }
    }
  }

  /// Writes the test twenty questions at a time, so it can be any length. The first call makes the
  /// paper and each later one adds to it.
  Future<void> _write() async {
    final total = _count!;
    setState(() {
      _busy = true;
      _error = null;
      _written = 0;
      _wanted = total;
    });
    String? paperId;
    String? stopped;
    try {
      for (var calls = 0; _written < total && calls < total + 5; calls++) {
        final left = total - _written;
        final r = await _ask({
          if (widget.courseId != null) 'course_id': widget.courseId else ...{'class_level': widget.classLevel, 'subject_id': widget.subjectId},
          'request': _text.text.trim(),
          'count': left < 20 ? left : 20,
          'paper_id': ?paperId,
        });
        paperId = '${r['paper']['id']}';
        if (mounted) setState(() => _written = (r['total'] as num).toInt());
      }
    } on ApiException catch (e) {
      stopped = e.message;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (paperId == null) {
      setState(() => _error = stopped);
      return;
    }
    if (stopped != null) {
      // Part of the test is written: say how much, then carry on with that.
      await showCentredCard<void>(
        context,
        title: 'Only ${f.count(_written, 'question')} written',
        builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Fig('You asked for $total. $stopped', style: bodyStyle.copyWith(color: muted)),
          const SizedBox(height: 18),
          PrimaryButton('Use these $_written', onTap: () => Navigator.of(ctx).pop()),
        ]),
      );
      if (!mounted) return;
    }
    context.pushReplacement('/t/papers/$paperId?read=1');
  }

  @override
  Widget build(BuildContext context) => PushedPanel(
        kicker: widget.courseId != null ? widget.subjectName : groupName(widget.classLevel!, widget.subjectName),
        title: 'Describe your test',
        footer: PrimaryButton(
          _busy ? 'Writing the questions' : 'Write the questions',
          leadingIcon: Ph.scan,
          busy: _busy,
          onTap: _ready ? _write : null,
          disabledReason: _busy || _ready ? null : (_text.text.trim().length < 5 ? 'Say what the test should cover.' : 'Type how many questions, from 1 to 1,000.'),
        ),
        children: [
          const SizedBox(height: 22),
          GroupedInputs(children: [
            BareField(
              controller: _text,
              placeholder: 'What should the test cover? For example: easy and medium questions on one topic',
              maxLines: null,
              minLines: 4,
              maxLength: 1500,
              capitalization: TextCapitalization.sentences,
            ),
          ]),
          const SizedBox(height: gapRow),
          GroupedInputs(children: [
            NamedField(name: 'Questions', controller: _countText, placeholder: 'How many', keyboard: TextInputType.number),
          ]),
          if (_error != null) ...[const SizedBox(height: 16), InlineNotice(_error!, tone: Tone.danger, icon: Ph.warning)],
          if (_busy) ...[
            const SizedBox(height: 16),
            InlineNotice(
              _waitLeft > 0
                  ? 'AI has used its limit for this minute. Carrying on in $_waitLeft s'
                  : _wanted > 20
                      ? 'Writing the questions: $_written of $_wanted done.'
                      : 'AI is writing the questions. This takes a few seconds.',
              tone: Tone.ai,
              icon: Ph.scan,
            ),
          ],
        ],
      );
}
