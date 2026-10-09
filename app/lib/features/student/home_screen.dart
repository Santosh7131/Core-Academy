import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';
import 'start_card.dart';

class StudentHome extends StatefulWidget {
  const StudentHome({super.key});

  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> with WidgetsBindingObserver, AutoRefresh<StudentHome> {
  List<Map<String, dynamic>>? _tests;
  String? _error;
  bool _loading = false;

  @override
  Set<Area> get refreshAreas => {Area.student};

  // A new test from the teacher shows up within a minute while this is on screen.
  @override
  Duration? get pollEvery => const Duration(seconds: 60);

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    markLoaded();
    setState(() => _loading = true);
    try {
      final r = await api.get('/student/home');
      _tests = (r['tests'] as List).cast<Map<String, dynamic>>();
      _error = null;
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(String path) async {
    await context.push(path);
    _load();
  }

  /// A test that has not been started asks first (what it holds, when the marks show); one under way carries on.
  Future<void> _start(Map<String, dynamic> t) async {
    if (t['state'] != 'in_progress' && !await confirmStart(context, t)) return;
    if (mounted) _open('/s/write/${t['id']}');
  }

  /// A student in several tuitions chooses which one the home shows.
  Future<void> _switchTuition() async {
    final c = await showChoices<String>(
      context,
      title: 'Tuition',
      options: [for (final t in session.activeTuitions) Choice('${t['id']}', '${t['name']}')],
      selected: session.tuitionId,
    );
    if (c?.value != null) session.switchTuition(c!.value!);
  }

  @override
  Widget build(BuildContext context) {
    final user = session.user ?? {};
    final tests = _tests;
    return Scaffold(
      body: SafeArea(
        child: PullToRefresh(
          onRefresh: _load,
          child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 32), physics: const AlwaysScrollableScrollPhysics(), children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const SizedBox(height: 14),
                    session.hasChoice
                        ? Pressable(
                            label: 'Change tuition',
                            onTap: _switchTuition,
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Flexible(child: Kicker('${session.tuitionName} · ${className(session.classLevel)}')),
                              const SizedBox(width: 6),
                              Icon(Ph.caretDown, size: 13, color: faint),
                            ]),
                          )
                        : Kicker('${session.tuitionName} · ${className(session.classLevel)}'),
                    const SizedBox(height: 6),
                    Text(session.firstName, style: displayStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ]),
                ),
                Pressable(
                  label: 'Profile',
                  onTap: () => context.push('/s/profile'),
                  child: AppAvatar(name: '${user['display_name'] ?? ''}', seed: '${user['id'] ?? ''}', size: 42),
                ),
              ]),
            ),
            const UpdateBanner(),
            if (tests == null && _error != null)
              ErrorState(message: _error!, onRetry: _load)
            else if (tests == null)
              const _HomeSkeleton()
            else ...[
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
                  child: InlineNotice(_error!, icon: Ph.warning),
                ),
              ..._sections(tests),
            ],
          ]),
        ),
      ),
    );
  }

  List<Widget> _sections(List<Map<String, dynamic>> tests) {
    List<Map<String, dynamic>> of(String s) => tests.where((t) => t['state'] == s).toList();
    final writing = of('in_progress');
    final open = of('open')..sort(_soonestClosing);
    final upcoming = of('upcoming');
    final done = of('done');
    final missed = of('missed');
    if (tests.isEmpty) {
      return [
        const SizedBox(height: 40),
        EmptyState(icon: Ph.exam, title: 'No tests yet', body: 'When your tutor gives you a test, it shows up here.'),
      ];
    }

    // The one thing to do now: a test under way, else the one that closes first.
    final current = [...writing, ...open];
    final hero = current.isEmpty ? null : current.first;
    final more = current.length > 1 ? current.sublist(1) : const <Map<String, dynamic>>[];

    String facts(Map<String, dynamic> t) {
      final parts = <String>[f.count(t['question_count'] as int, 'question')];
      if (t['time_limit_min'] != null) parts.add('${t['time_limit_min']} min');
      return parts.join(' · ');
    }

    Widget group(String label, int count, List<Widget> rows, {bool alert = false, Widget? trailing}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionRule(label, count: count, alert: alert, trailing: trailing),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Column(children: [
              for (final (i, r) in rows.indexed) ...[if (i > 0) const SizedBox(height: gapRow), r],
            ]),
          ),
        ]);

    Widget openRow(Map<String, dynamic> t) {
      final resume = t['state'] == 'in_progress';
      final closes = f.parseTime(t['closes_at']);
      return RowTile(
        title: '${t['title']}',
        meta: resume ? 'Under way · tap to continue' : (closes == null ? facts(t) : '${facts(t)} · closes ${f.when(closes)}'),
        trailing: resume ? const TagChip('Resume', tone: Tone.warning) : null,
        chevron: !resume,
        onTap: () => _start(t),
      );
    }

    final shown = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
        child: hero == null ? _AllCaughtUp(next: upcoming.isEmpty ? null : upcoming.first) : _Hero(test: hero, onStart: () => _start(hero)),
      ),
      if (more.isNotEmpty) group('Also open', more.length, [for (final t in more) openRow(t)]),
      if (done.isNotEmpty)
        group(
          'Results',
          done.length,
          [
            for (final t in done.take(3))
              Builder(builder: (context) {
                final a = t['attempt'] as Map<String, dynamic>;
                final submitted = f.parseTime(a['submitted_at']);
                // Marks stay hidden until the test closes, everyone has finished, or the tutor shows them.
                final open = t['results_open'] != false;
                final closes = f.parseTime(t['closes_at']);
                return RowTile(
                  title: '${t['title']}',
                  meta: !open
                      ? 'Submitted · marks ${closes == null ? 'soon' : 'after ${f.when(closes)}'}'
                      : (submitted == null ? null : 'Submitted ${f.when(submitted)}'),
                  trailing: open ? Text('${f.marks(a['score'])}/${f.marks(a['max_score'])}', style: numStyle(size: 15)) : const TagChip('Marks later'),
                  onTap: open ? () => _open('/s/result/${a['id']}') : null,
                );
              }),
          ],
          trailing: Pressable(
            label: 'All results',
            onTap: () => context.push('/s/results'),
            child: Text('All results', style: chipStyle.copyWith(color: muted, fontWeight: FontWeight.w600)),
          ),
        ),
      if (upcoming.isNotEmpty)
        group('Coming up', upcoming.length, [
          for (final t in upcoming)
            RowTile(
              title: '${t['title']}',
              meta: 'Opens ${f.parseTime(t['opens_at']) == null ? '' : f.when(f.parseTime(t['opens_at'])!)} · ${facts(t)}',
            ),
        ]),
      if (missed.isNotEmpty)
        group('Missed', missed.length, [
          for (final t in missed)
            RowTile(title: '${t['title']}', meta: f.parseTime(t['closes_at']) == null ? null : 'Closed ${f.when(f.parseTime(t['closes_at'])!)}'),
        ], alert: true),
    ];
    return staggered(shown, scope: this, prefix: 'home', stepMs: 70);
  }

  /// Tests that close sooner first; one with no closing time last.
  static int _soonestClosing(Map<String, dynamic> a, Map<String, dynamic> b) {
    final x = f.parseTime(a['closes_at']);
    final y = f.parseTime(b['closes_at']);
    if (x == null && y == null) return 0;
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }
}

/// The test to write now, with its one button.
class _Hero extends StatelessWidget {
  const _Hero({required this.test, required this.onStart});
  final Map<String, dynamic> test;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final resume = test['state'] == 'in_progress';
    final closes = f.parseTime(test['closes_at']);
    final deadline = f.parseTime(test['attempt']?['deadline_at']);
    final soon = closes != null && closes.difference(DateTime.now()).inHours < 3;
    final limit = test['time_limit_min'] as int?;
    final facts = [
      f.count(test['question_count'] as int, 'question'),
      if (limit != null) '$limit min',
      if (!resume && closes != null) 'closes ${f.time(closes)}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: surface(radius: rHero, shadow: e3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Kicker(resume ? 'Under way' : 'Open now'),
          const Spacer(),
          if (resume && deadline != null)
            TagChip('Ends ${f.time(deadline)}', tone: Tone.warning)
          else if (closes != null)
            TagChip('${f.left(closes)} left', tone: soon ? Tone.warning : Tone.neutral),
        ]),
        const SizedBox(height: 14),
        Fig('${test['title']}', style: titleStyle, maxLines: 2),
        const SizedBox(height: 9),
        Fig(facts, style: labelStyle.copyWith(fontSize: 12.5), numColor: ink),
        const SizedBox(height: 20),
        PrimaryButton(resume ? 'Continue test' : 'Start test', icon: Ph.arrowRight, onTap: onStart),
      ]),
    );
  }
}

/// Nothing to write right now: says so, and when the next test opens if there is one.
class _AllCaughtUp extends StatelessWidget {
  const _AllCaughtUp({this.next});
  final Map<String, dynamic>? next;

  @override
  Widget build(BuildContext context) {
    final opens = next == null ? null : f.parseTime(next!['opens_at']);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
      decoration: surface(radius: rHero, shadow: e3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: successSoft, shape: BoxShape.circle),
          child: Icon(Ph.check, size: 22, color: success),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Nothing to write now', style: sectionStyle),
            const SizedBox(height: 4),
            Fig(
              next == null ? 'Your next test shows up here.' : '${next!['title']} opens ${opens == null ? 'soon' : f.when(opens)}.',
              style: labelStyle.copyWith(fontSize: 12.5),
              maxLines: 2,
            ),
          ]),
        ),
      ]),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) => const SkeletonScope(
        child: Padding(
          padding: EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
          child: Column(children: [
            SkeletonHero(height: 214),
            SizedBox(height: 34),
            SkeletonRows(count: 3, padding: EdgeInsets.zero),
          ]),
        ),
      );
}
