import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';

/// The teacher's home: today's figures, live tests, who needs attention, recent activity.
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> with WidgetsBindingObserver {
  Map<String, dynamic>? _d;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    // Live counts refresh every 30 s while this screen is open.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load(quiet: true);
  }

  Future<void> _load({bool quiet = false}) async {
    try {
      final d = await api.get('/teacher/dashboard');
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
    final now = DateTime.now();
    final d = _d;
    return SafeArea(
      bottom: false,
      child: ListView(padding: EdgeInsets.zero, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Kicker('${session.tuitionName} · ${DateFormat('d MMMM').format(now)}'),
                const SizedBox(height: 6),
                Text(DateFormat('EEEE').format(now), style: displayStyle),
              ]),
            ),
            CircleBtn(icon: Ph.arrowsClockwise, label: 'Refresh', onTap: _load),
            const SizedBox(width: 10),
            Pressable(
              label: 'Settings',
              onTap: () => context.push('/t/settings'),
              child: AppAvatar(name: '${session.user?['display_name'] ?? ''}', seed: '${session.user?['id'] ?? ''}', size: 40),
            ),
          ]),
        ),
        if (d == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (d == null)
          const LoadingState()
        else
          ..._body(d),
        navClearance,
      ]),
    );
  }

  List<Widget> _body(Map<String, dynamic> d) {
    final s = Map<String, dynamic>.from(d['stats']);
    final live = (d['live'] as List).cast<Map<String, dynamic>>();
    final attention = (d['attention'] as List).cast<Map<String, dynamic>>();
    final activity = (d['activity'] as List).cast<Map<String, dynamic>>();
    final due = s['due_today'] as int;

    Widget rows(List<Widget> children) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          child: Column(children: [
            for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: gapRow), c],
          ]),
        );

    return [
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 0), child: InlineNotice(_error!, icon: Ph.warning)),
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
        child: StatGrid(
          label: 'Submitted today',
          value: '${s['submitted_today']}',
          note: due > 0 ? 'of $due students given a test today' : 'No timed tests today',
          small: [
            StatSmall('Writing now', '${s['writing_now']}'),
            StatSmall('Missed this week', '${s['missed_week']}'),
          ],
        ),
      ),
      SectionRule('Live now', count: live.length),
      if (live.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          child: Text('No test is open right now.', style: bodyStyle.copyWith(color: muted)),
        )
      else ...[
        // The three closing soonest (the API sorts by closing time); the rest are in Tests.
        rows([
          for (final t in live.take(3))
            RowTile(
              title: '${t['title']} · Class ${t['class_level']}',
              meta: _liveMeta(t),
              metaColor: _closingSoon(t) ? warning : null,
              trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${t['submitted']}/${t['assigned']}', style: numStyle(size: 15)),
                const SizedBox(height: 3),
                Text('submitted', style: labelStyle),
              ]),
              onTap: () => context.push('/t/tests/${t['id']}'),
            ),
        ]),
        if (live.length > 3)
          Center(child: TextAction('See all ${live.length} open tests', onTap: () => context.go('/t/tests'))),
      ],
      if (attention.isNotEmpty) ...[
        SectionRule('Needs attention', count: attention.length, alert: true),
        rows([
          for (final u in attention)
            RowTile(
              leading: AppAvatar(name: '${u['display_name']}', seed: '${u['id']}'),
              title: '${u['display_name']}',
              meta: 'Class ${u['class_level']} · ${_attentionReason(u)}',
              chevron: true,
              onTap: () => context.push('/t/students/${u['id']}'),
            ),
        ]),
      ],
      SectionRule('Activity', count: activity.isEmpty ? null : activity.length),
      if (activity.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          child: Text('Nothing yet. Activity shows up here when students start or submit tests.', style: bodyStyle.copyWith(color: muted)),
        )
      else
        rows([
          for (final a in activity)
            RowTile(
              leading: AppAvatar(name: '${a['display_name']}', seed: '${a['student_id']}'),
              title: '${a['display_name']}',
              meta: '${a['kind'] == 'submitted' ? 'Submitted' : 'Started'} ${a['title']} · ${f.relative(f.parseTime(a['at'])!)}',
              trailing: a['kind'] == 'submitted'
                  ? Text('${f.marks(a['score'])}/${f.marks(a['max_score'])}', style: numStyle(size: 15))
                  : const TagChip('Writing', tone: Tone.warning),
              onTap: a['kind'] == 'submitted' ? () => context.push('/t/attempts/${a['attempt_id']}') : null,
            ),
        ]),
    ];
  }

  bool _closingSoon(Map<String, dynamic> t) {
    final c = f.parseTime(t['closes_at']);
    return c != null && c.difference(DateTime.now()).inMinutes < 60;
  }

  String _liveMeta(Map<String, dynamic> t) {
    final c = f.parseTime(t['closes_at']);
    final parts = <String>[];
    if (c != null) {
      final mins = c.difference(DateTime.now()).inMinutes;
      parts.add(mins < 60 ? 'closes in $mins min' : 'closes ${f.when(c)}');
    }
    if ((t['writing'] as int) > 0) parts.add('${t['writing']} writing');
    return parts.isEmpty ? 'Open, no closing time' : parts.join(' · ');
  }

  String _attentionReason(Map<String, dynamic> u) {
    final missed = u['missed'] as int;
    if (missed >= 2) return 'missed $missed tests this week';
    return 'below 40% in the last ${u['recent_count']} tests';
  }
}
