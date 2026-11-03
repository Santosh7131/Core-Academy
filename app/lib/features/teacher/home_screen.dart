import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/brand.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';
import 'classes_screen.dart' show addGroupOrCourse;
import 'common.dart';
import 'make_test.dart';
import 'papers_screens.dart' show paperGroup, paperName;
import 'tests_screens.dart' show TestRow;

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

// ---------------------------------------------------------------- home

/// The tutor's home, in the order a tutor needs it: one button to make a test, what needs her, the tests students can write now,
/// the ones coming up and the ones that finished lately. The groups and courses themselves are on the Groups & courses tab.
class TutorHome extends StatefulWidget {
  const TutorHome({super.key});

  @override
  State<TutorHome> createState() => _TutorHomeState();
}

class _TutorHomeState extends State<TutorHome> with WidgetsBindingObserver, AutoRefresh<TutorHome> {
  Map<String, dynamic>? _d;
  String? _error;

  /// What Home says after a test was closed or the students were reminded. It goes at the next refresh the tutor asks for.
  String? _notice;

  /// The test being closed or reminded about: its two buttons wait for the answer.
  String? _acting;

  /// The lists the tutor has opened in full (a long one shows its first few).
  final Set<String> _all = {};

  @override
  Set<Area> get refreshAreas => {Area.tests, Area.students, Area.papers, Area.courses};

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
      final d = await api.get('/teacher/home');
      if (mounted) {
        setState(() {
          _d = Map<String, dynamic>.from(d);
          _error = null;
          if (!quiet) _notice = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted && !quiet) setState(() => _error = e.message);
    }
  }

  List<Map<String, dynamic>> _list(Map<String, dynamic> d, String key) => ((d[key] as List?) ?? const []).cast<Map<String, dynamic>>();

  List<TestTarget> _targets(Map<String, dynamic> d) => [
        for (final g in _list(d, 'groups')) TestTarget.fromGroup(g),
        for (final c in _list(d, 'courses')) TestTarget.fromCourse(c),
      ];

  Future<void> _make(Map<String, dynamic> d) async {
    if (await makeTest(context, _targets(d)) && mounted) _load();
  }

  Future<void> _addGroupOrCourse() async {
    await addGroupOrCourse(context);
    if (mounted) _load();
  }

  Future<void> _go(String path) async {
    await context.push(path);
    if (mounted) _load();
  }

  /// Sends the students who have not handed a test in a reminder, once the tutor has seen the notification they will get.
  Future<void> _remind(Map<String, dynamic> t) async {
    final id = '${t['id']}';
    if (!await confirmRemind(context, title: '${t['title']}', waiting: _n(t['waiting']), closes: f.parseTime(t['closes_at']))) return;
    setState(() => _acting = id);
    try {
      final r = await api.post('/teacher/tests/$id/remind');
      if (mounted) setState(() => _notice = 'Reminder sent to ${f.count(_n(r['students']), 'student')}.');
    } on ApiException catch (e) {
      if (mounted) await showProblem(context, e);
    } finally {
      if (mounted) setState(() => _acting = null);
    }
    if (mounted) _load(quiet: true);
  }

  /// Closes a test now, once the tutor has read what that does.
  Future<void> _close(Map<String, dynamic> t) async {
    final id = '${t['id']}';
    if (!await confirmCloseTest(context, title: '${t['title']}', closes: f.parseTime(t['closes_at']))) return;
    setState(() => _acting = id);
    try {
      await api.post('/teacher/tests/$id/close');
      if (mounted) setState(() => _notice = '${t['title']} is closed. Anyone still writing it has $closeGraceMinutes minutes.');
    } on ApiException catch (e) {
      if (mounted) await showProblem(context, e);
    } finally {
      if (mounted) setState(() => _acting = null);
    }
    if (mounted) _load(quiet: true);
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
              Pressable(
                label: 'Settings',
                onTap: () => context.push('/t/settings'),
                child: AppAvatar(name: '${session.user?['display_name'] ?? ''}', seed: '${session.user?['id'] ?? ''}', size: 42),
              ),
            ]),
          ),
          const UpdateBanner(),
          if (d == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (d == null)
            const LoadingState(inset: true, rows: 3)
          else
            ...staggered(_body(d), scope: this, prefix: 'home', stepMs: 60),
          navClearance,
        ]),
      ),
    );
  }

  /// The name of the class a test belongs to, for the line under its title.
  String _classOf(Map<String, dynamic> t, {Map<String, dynamic>? group, Map<String, dynamic>? course}) {
    if (course != null) return '${course['name']}';
    if (group != null) return groupName(group['class_level'] as int, '${group['subject']}');
    if (t['course_id'] != null) return '${t['course']}';
    return groupName(t['class_level'] as int, '${t['subject']}');
  }

  List<Widget> _body(Map<String, dynamic> d) {
    final groups = _list(d, 'groups');
    final courses = _list(d, 'courses');
    final finished = _list(d, 'finished');
    final papers = _list(d, 'papers');
    final pending = _n(d['pending_requests']);
    final code = '${d['tuition']?['join_code'] ?? ''}';
    final noStudents = groups.every((g) => _n(g['students']) == 0) && courses.every((c) => _n(c['people']) == 0);
    final hasClass = groups.isNotEmpty || courses.isNotEmpty;

    // Every test that is open now or coming up, with the class it is for, from the groups and from the courses.
    final open = <({Map<String, dynamic> t, String cls})>[];
    final coming = <({Map<String, dynamic> t, String cls})>[];
    for (final g in groups) {
      for (final t in (g['live'] as List).cast<Map<String, dynamic>>()) {
        open.add((t: t, cls: _classOf(t, group: g)));
      }
      for (final t in (g['posted'] as List).cast<Map<String, dynamic>>()) {
        coming.add((t: t, cls: _classOf(t, group: g)));
      }
    }
    for (final c in courses) {
      for (final t in (c['live'] as List).cast<Map<String, dynamic>>()) {
        open.add((t: t, cls: _classOf(t, course: c)));
      }
      for (final t in (c['posted'] as List).cast<Map<String, dynamic>>()) {
        coming.add((t: t, cls: _classOf(t, course: c)));
      }
    }
    // What closes first comes first; a test with no closing time goes last. What opens first comes first.
    DateTime far(DateTime? t) => t ?? DateTime(9999);
    open.sort((a, b) => far(f.parseTime(a.t['closes_at'])).compareTo(far(f.parseTime(b.t['closes_at']))));
    coming.sort((a, b) => far(f.parseTime(a.t['opens_at'])).compareTo(far(f.parseTime(b.t['opens_at']))));

    Widget pad(Widget w, {double top = 0}) => Padding(padding: EdgeInsets.fromLTRB(gutter, top, gutter, 0), child: w);
    Widget rows(List<Widget> list) => pad(Column(children: [
          for (final (i, w) in list.indexed) ...[if (i > 0) const SizedBox(height: gapRow), w],
        ]));
    // A long list shows its first few, and the rest on a tap.
    Widget capped(String key, int shown, List<Widget> list) {
      final more = list.length > shown && !_all.contains(key);
      return Column(children: [
        rows(more ? list.take(shown).toList() : list),
        if (list.length > shown)
          Center(
            child: TextAction(
              more ? 'Show all ${list.length}' : 'Show fewer',
              onTap: () => setState(() => more ? _all.add(key) : _all.remove(key)),
            ),
          ),
      ]);
    }

    // Tests that have been open for a week: two cards at most, the rest on a tap.
    final stale = _list(d, 'stale');
    final staleShown = _all.contains('stale') ? stale : stale.take(2).toList();

    final needs = <Widget>[
      if (pending > 0)
        RowTile(
          leading: _badge(Ph.userPlus),
          title: pending == 1 ? '1 student wants to join' : '$pending students want to join',
          meta: 'Choose their class and subjects',
          chevron: true,
          onTap: () => _go('/t/requests'),
        ),
      if (papers.isNotEmpty)
        RowTile(
          leading: _badge(Ph.fileText),
          title: papers.length == 1 ? '1 paper to finish' : '${papers.length} papers to finish',
          meta: papers.length == 1 ? '${paperName(papers.first)} · ${paperGroup(papers.first)}' : '${paperName(papers.first)} and ${papers.length - 1} more',
          chevron: true,
          onTap: () => _go(papers.length == 1 ? '/t/papers/${papers.first['id']}' : '/t/papers'),
        ),
      if (pending == 0 && noStudents && hasClass && code.length == 6)
        RowTile(
          leading: _badge(Ph.shareNetwork),
          title: 'Invite your students',
          meta: 'Join code ${code.substring(0, 3)}-${code.substring(3)}',
          chevron: true,
          onTap: () => _go('/t/code'),
        ),
    ];

    return [
      if (_error != null) pad(InlineNotice(_error!, icon: Ph.warning), top: 16),
      if (!hasClass)
        EmptyState(
          icon: Ph.users,
          title: 'No groups or courses yet',
          body: 'Add a group, like 10th Maths, or a course. Then you can add your people and make your first test.',
          action: PrimaryButton('Add a group or course', leadingIcon: Ph.plus, onTap: _addGroupOrCourse),
        )
      else
        pad(PrimaryButton('Make tests', leadingIcon: Ph.plus, onTap: () => _make(d)), top: 18),
      if (_notice != null) pad(InlineNotice(_notice!, tone: Tone.success, icon: Ph.checkCircle), top: 16),
      // A test left open for a week comes first, with what the tutor can do about it.
      if (staleShown.isNotEmpty) ...[
        pad(
          Column(children: [
            for (final (i, t) in staleShown.indexed) ...[
              if (i > 0) const SizedBox(height: gapRow),
              _StaleCard(t: t, cls: _classOf(t), busy: _acting == '${t['id']}', onRemind: () => _remind(t), onClose: () => _close(t)),
            ],
          ]),
          top: 16,
        ),
        if (stale.length > 2)
          Center(
            child: TextAction(
              _all.contains('stale') ? 'Show fewer' : 'Show all ${stale.length} tests open for a week',
              onTap: () => setState(() => _all.contains('stale') ? _all.remove('stale') : _all.add('stale')),
            ),
          ),
      ],
      // What needs the tutor, then every test in one list: each row says by its tag whether it is open now, coming up or finished.
      if (needs.isNotEmpty) pad(Column(children: [for (final (i, w) in needs.indexed) ...[if (i > 0) const SizedBox(height: gapRow), w]]), top: 16),
      if (hasClass && open.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
          child: Fig('No test is open right now.', style: bodyStyle.copyWith(color: muted)),
        ),
      if (open.isNotEmpty || coming.isNotEmpty || finished.isNotEmpty) ...[
        pad(const SizedBox(height: 0), top: 10),
        capped('tests', 8, [
          for (final o in open) _OpenTest(t: o.t, cls: o.cls, onTap: () => _go('/t/tests/${o.t['id']}')),
          for (final o in coming) _ComingTest(t: o.t, cls: o.cls, onTap: () => _go('/t/tests/${o.t['id']}')),
          for (final t in finished) _FinishedTest(t: t, cls: _classOf(t), onTap: () => _go('/t/tests/${t['id']}')),
        ]),
      ],
      if (finished.isNotEmpty)
        pad(
          Fig('Older tests are on each group\'s or course\'s page, under Groups & courses.', style: labelStyle),
          top: 12,
        ),
      if (hasClass && open.isEmpty && coming.isEmpty && finished.isEmpty)
        EmptyState(
          icon: Ph.exam,
          title: 'No tests yet',
          body: 'Tap Make tests. Add question papers and AI reads the questions, or describe a test and AI writes it.',
        ),
    ];
  }

  /// The soft square an item that needs the tutor starts with.
  Widget _badge(IconData icon) => Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: warningSoft, borderRadius: BorderRadius.circular(rSmall)),
        child: Icon(icon, size: 20, color: warning),
      );
}

// ---------------------------------------------------------------- test rows

/// A test students can write now: its name, its class and when it closes, and how many have handed it in.
class _OpenTest extends StatelessWidget {
  const _OpenTest({required this.t, required this.cls, required this.onTap});
  final Map<String, dynamic> t;
  final String cls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final closes = f.parseTime(t['closes_at']);
    return TestRow(
      t: t,
      state: 'open',
      meta: '$cls · ${closes == null ? 'open' : 'closes ${f.whenDate(closes)}'}',
      onTap: onTap,
    );
  }
}

/// A test posted for later: its name, its class, and the day, date and time it opens.
class _ComingTest extends StatelessWidget {
  const _ComingTest({required this.t, required this.cls, required this.onTap});
  final Map<String, dynamic> t;
  final String cls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final opens = f.parseTime(t['opens_at']);
    return TestRow(
      t: t,
      state: 'upcoming',
      // The day name and date are always there; "tomorrow" alone leaves her to work out which day that is.
      meta: '$cls · opens ${opens == null ? 'later' : f.whenDate(opens)}',
      onTap: onTap,
    );
  }
}

/// A test that has finished: its name, its class and when it closed, and how many handed it in.
class _FinishedTest extends StatelessWidget {
  const _FinishedTest({required this.t, required this.cls, required this.onTap});
  final Map<String, dynamic> t;
  final String cls;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final closes = f.parseTime(t['closes_at']);
    // Everyone it was given to handed it in before its closing time: it finished early.
    final early = closes != null && closes.isAfter(DateTime.now());
    return TestRow(
      t: t,
      state: 'closed',
      meta: '$cls · ${closes == null || early ? 'all handed in' : 'closed ${f.dayDate(closes)}'}',
      onTap: onTap,
    );
  }
}

// ---------------------------------------------------------------- a test left open for a week

/// The minutes a student who is still writing gets when a test is closed from Home. It is CLOSE_GRACE_MIN in the API (api/src/lib/stale.ts).
const closeGraceMinutes = 10;

/// A test that has been open for a week: how long, how many students have not handed it in, and the two things the tutor can do about it.
class _StaleCard extends StatelessWidget {
  const _StaleCard({required this.t, required this.cls, required this.busy, required this.onRemind, required this.onClose});
  final Map<String, dynamic> t;
  final String cls;
  final bool busy;
  final VoidCallback onRemind;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: surface(radius: rCard, shadow: e1),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: warningSoft, borderRadius: BorderRadius.circular(13)),
            child: Icon(Ph.hourglassMedium, size: 21, color: warning),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Kicker('Open for ${f.count(_n(t['days_open']), 'day')}', color: warning),
              const SizedBox(height: 3),
              Fig('${t['title']}', style: rowTitleStyle, maxLines: 1),
              const SizedBox(height: 2),
              Fig('$cls · ${_n(t['waiting'])} of ${_n(t['assigned'])} have not handed it in', style: labelStyle.copyWith(color: muted), maxLines: 2),
            ]),
          ),
        ]),
        const SizedBox(height: 13),
        // Side by side, and as tall as the taller one when large text makes a label wrap.
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: _StaleButton(label: 'Remind the students', icon: Ph.bellRinging, filled: true, onTap: busy ? null : onRemind)),
            const SizedBox(width: 8),
            Expanded(child: _StaleButton(label: 'Close the test', icon: Ph.lockSimple, onTap: busy ? null : onClose)),
          ]),
        ),
      ]),
    );
  }
}

class _StaleButton extends StatelessWidget {
  const _StaleButton({required this.label, required this.icon, this.filled = false, this.onTap});
  final String label;
  final IconData icon;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final on = filled && onTap != null;
    final fg = onTap == null ? faint : (filled ? actionInk : ink);
    return Pressable(
      onTap: onTap,
      label: label,
      child: Container(
        constraints: const BoxConstraints(minHeight: 42),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: on ? actionFill : fill, borderRadius: BorderRadius.circular(13), boxShadow: on ? e2 : const []),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 15, color: fg),
          const SizedBox(width: 6),
          Flexible(child: Text(label, style: buttonStyle.copyWith(fontSize: 12.5, color: fg), textAlign: TextAlign.center, maxLines: 2)),
        ]),
      ),
    );
  }
}

/// A sentence with some words in full ink and bold: [parts] are the pieces in order, each with whether it is one of those words.
Widget _sentence(List<(String, bool)> parts) => Text.rich(TextSpan(children: [
      for (final (text, strong) in parts) figSpan(text, strong ? bodyStyle.copyWith(color: ink, fontWeight: FontWeight.w600) : bodyStyle),
    ]));

/// One thing that happens, with an icon, in the card that asks the tutor to confirm.
class _Point extends StatelessWidget {
  const _Point(this.icon, this.parts);
  final IconData icon;
  final List<(String, bool)> parts;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 17, color: muted)),
          const SizedBox(width: 10),
          Expanded(child: _sentence(parts)),
        ]),
      );
}

/// A notification as a student's phone will show it, word for word what the server sends.
class _NotificationPreview extends StatelessWidget {
  const _NotificationPreview({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(15, 12, 15, 14),
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(18)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(color: actionFill, borderRadius: BorderRadius.circular(6)),
              child: Icon(Ph.graduationCap, size: 11, color: actionInk),
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(appName, style: labelStyle.copyWith(fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Text('now', style: labelStyle.copyWith(fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 8),
          Fig(title, style: rowTitleStyle, maxLines: 2),
          const SizedBox(height: 3),
          Fig(body, style: bodyStyle.copyWith(fontSize: 13)),
        ]),
      );
}

/// What closing a test does, before it is done. Returns true when the tutor goes ahead.
Future<bool> confirmCloseTest(BuildContext context, {required String title, required DateTime? closes}) async {
  final ok = await showCentredCard<bool>(
    context,
    title: 'Close this test now?',
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sentence([
        (title, true),
        if (closes == null) (' has no closing time. If you close it now:', false) else ...[(' is open until ', false), (f.whenDate(closes), true), ('. If you close it now:', false)],
      ]),
      const SizedBox(height: 3),
      const _Point(Ph.prohibit, [('Students who have not started it can no longer write it.', false)]),
      const _Point(Ph.timer, [('Anyone writing it right now gets ', false), ('$closeGraceMinutes minutes', true), (' to finish.', false)]),
      const _Point(Ph.checkCircle, [('Everyone who handed it in keeps their marks.', false)]),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: SecondaryButton('Keep it open', onTap: () => Navigator.of(ctx).pop(false))),
        const SizedBox(width: 10),
        Expanded(child: SecondaryButton('Close the test', tint: danger, onTap: () => Navigator.of(ctx).pop(true))),
      ]),
    ]),
  );
  return ok ?? false;
}

/// How many students will be reminded and the notification each gets, before anything is sent. Returns true when the tutor sends it.
Future<bool> confirmRemind(BuildContext context, {required String title, required int waiting, required DateTime? closes}) async {
  final closing = closes == null ? 'It is still open.' : 'It closes ${f.when(closes)}.';
  final ok = await showCentredCard<bool>(
    context,
    title: 'Remind the students?',
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sentence([
        ('${f.count(waiting, 'student')} ${waiting == 1 ? 'has' : 'have'} not handed in ', false),
        (title, true),
        (waiting == 1 ? '. They get this notification:' : '. Each one gets this notification:', false),
      ]),
      const SizedBox(height: 12),
      _NotificationPreview(title: title, body: 'Your tutor reminds you to write this test. $closing'),
      const SizedBox(height: 12),
      _sentence([('After you send it, this card goes away for a week.', false)]),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: SecondaryButton('Not now', onTap: () => Navigator.of(ctx).pop(false))),
        const SizedBox(width: 10),
        Expanded(child: PrimaryButton('Send reminder', onTap: () => Navigator.of(ctx).pop(true))),
      ]),
    ]),
  );
  return ok ?? false;
}

// ---------------------------------------------------------------- papers to finish

/// Every question paper the tutor started and has not finished, so one left half way is easy to find again.
class PapersToFinishScreen extends StatefulWidget {
  const PapersToFinishScreen({super.key});

  @override
  State<PapersToFinishScreen> createState() => _PapersToFinishScreenState();
}

class _PapersToFinishScreenState extends State<PapersToFinishScreen> with WidgetsBindingObserver, AutoRefresh<PapersToFinishScreen> {
  List<Map<String, dynamic>>? _papers;
  String? _error;

  @override
  Set<Area> get refreshAreas => {Area.papers, Area.tests};

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
          _papers = ((d['papers'] as List?) ?? const []).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// What is left to do on a paper, in a few words.
  String _left(Map<String, dynamic> p) {
    final toCheck = _n(p['to_check']);
    if (toCheck > 0) return '${f.count(toCheck, 'question')} to check';
    final unread = _n(p['page_count']) - _n(p['pages_read']);
    if (unread > 0) return '${_n(p['pages_read'])} of ${f.count(_n(p['page_count']), 'page')} read';
    return 'Ready to make a test';
  }

  Future<void> _open(Map<String, dynamic> p) async {
    await context.push('/t/papers/${p['id']}');
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final papers = _papers;
    return PushedPanel(
      onRefresh: _load,
      kicker: 'Question papers',
      title: 'Papers to finish',
      children: [
        const SizedBox(height: 18),
        if (papers == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (papers == null)
          const LoadingState(rows: 3)
        else if (papers.isEmpty)
          const EmptyState(icon: Ph.fileText, title: 'Nothing is waiting', body: 'Every paper you started is finished.')
        else
          for (final (i, p) in papers.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              leading: Icon(Ph.fileText, size: 22, color: ink),
              title: paperName(p),
              meta: '${paperGroup(p)} · ${_left(p)}',
              chevron: true,
              onTap: () => _open(p),
            ),
          ],
      ],
    );
  }
}
