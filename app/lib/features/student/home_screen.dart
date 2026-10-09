import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';
import '../../core/levels.dart';

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
          child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 28), physics: const AlwaysScrollableScrollPhysics(), children: [
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
                RefreshButton(onRefresh: _load),
                const SizedBox(width: 10),
                Pressable(
                  label: 'Profile',
                  onTap: () => context.push('/s/profile'),
                  child: AppAvatar(name: '${user['display_name'] ?? ''}', seed: '${user['id'] ?? ''}', size: 40),
                ),
              ]),
            ),
            const UpdateBanner(),
            if (tests == null && _error != null)
              ErrorState(message: _error!, onRetry: _load)
            else if (tests == null)
              const LoadingState()
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
    final open = of('open');
    final upcoming = of('upcoming');
    final done = of('done');
    final missed = of('missed');
    if (tests.isEmpty) {
      return [
        const SizedBox(height: 40),
        EmptyState(icon: Ph.exam, title: 'No tests yet', body: 'When your teacher gives you a test, it will show up here.'),
      ];
    }

    Widget section(String label, List<Map<String, dynamic>> list, Widget Function(Map<String, dynamic>) row, {bool alert = false}) =>
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionRule(label, count: list.length, alert: alert),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: Column(children: [
              for (final (i, t) in list.indexed) ...[if (i > 0) const SizedBox(height: gapRow), row(t)],
            ]),
          ),
        ]);

    String facts(Map<String, dynamic> t) {
      final parts = <String>[f.count(t['question_count'] as int, 'question')];
      if (t['time_limit_min'] != null) parts.add('${t['time_limit_min']} min');
      return parts.join(' · ');
    }

    return [
      if (writing.isNotEmpty)
        section('Writing now', writing, (t) {
          final deadline = f.parseTime(t['attempt']?['deadline_at']);
          return RowTile(
            title: '${t['title']}',
            meta: deadline == null ? 'No time limit · tap to continue' : 'Ends ${f.when(deadline)}',
            trailing: const TagChip('Resume', tone: Tone.warning),
            onTap: () => _open('/s/write/${t['id']}'),
          );
        }),
      if (open.isNotEmpty)
        section('Open now', open, (t) {
          final closes = f.parseTime(t['closes_at']);
          final soon = closes != null && closes.difference(DateTime.now()).inHours < 3;
          return RowTile(
            title: '${t['title']}',
            meta: closes == null ? facts(t) : '${facts(t)} · closes ${f.when(closes)}',
            metaColor: soon ? warning : null,
            chevron: true,
            onTap: () => _open('/s/test/${t['id']}'),
          );
        }),
      if (upcoming.isNotEmpty)
        section('Coming up', upcoming, (t) {
          final opens = f.parseTime(t['opens_at']);
          return RowTile(title: '${t['title']}', meta: 'Opens ${opens == null ? '' : f.when(opens)} · ${facts(t)}');
        }),
      if (done.isNotEmpty)
        section('Completed', done, (t) {
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
      if (missed.isNotEmpty)
        section('Missed', missed, (t) {
          final closes = f.parseTime(t['closes_at']);
          return RowTile(title: '${t['title']}', meta: closes == null ? null : 'Closed ${f.when(closes)}');
        }, alert: true),
      const SizedBox(height: 18),
      Center(child: TextAction('All my results', onTap: () => context.push('/s/results'))),
    ];
  }
}
