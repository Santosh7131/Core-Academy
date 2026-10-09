import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/api.dart';
import '../core/auto_refresh.dart';
import '../core/format.dart' as f;
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';

const _rule = EdgeInsets.fromLTRB(0, 26, 0, 11);

String _task(String t) => switch (t) {
      'read_paper_page' => 'Reading paper pages',
      'detect_paper' => 'Finding class and subject',
      'answer_questions' => 'Answering questions',
      'second_opinion' => 'Second opinions',
      'write_questions' => 'Writing questions',
      'spell_name' => 'Spelling names',
      _ => t,
    };

String _model(String m) => switch (m) {
      'gemini-3.5-flash-lite' => 'Gemini 3.5 Flash-Lite',
      'gemini-3.1-flash-lite' => 'Gemini 3.1 Flash-Lite',
      'gemini-3.5-flash' => 'Gemini 3.5 Flash',
      'gemini-3.6-flash' => 'Gemini 3.6 Flash',
      'openai/gpt-oss-120b' => 'gpt-oss-120b',
      'openai/gpt-oss-20b' => 'gpt-oss-20b',
      'qwen/qwen3.8-27b' => 'Qwen 3.8 27B',
      _ => m,
    };

/// One client as a pushed panel like the account page: its size, API requests, AI cost, tutors and
/// classes. Students are only numbers here; their names stay in the tutor's own app.
class ClientScreen extends StatefulWidget {
  const ClientScreen({super.key, required this.id, this.name});
  final String id;

  /// Shown while the page loads.
  final String? name;

  @override
  State<ClientScreen> createState() => _ClientScreenState();
}

class _ClientScreenState extends State<ClientScreen> with WidgetsBindingObserver, AutoRefresh<ClientScreen> {
  Map<String, dynamic>? _d;
  String? _error;

  @override
  Duration? get pollEvery => const Duration(seconds: 90);

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.get('/admin/clients/${widget.id}');
      if (!mounted) return;
      markLoaded();
      setState(() {
        _d = Map<String, dynamic>.from(d);
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted && _d == null) setState(() => _error = e.message);
    }
  }

  /// One value per day for the last [n] days, today last (the server's days are India dates).
  List<double> _perDay(List<Map<String, dynamic>> rows, String field, {int n = 14}) {
    final byDay = {for (final x in rows) '${x['day']}': f.asDouble(x[field])};
    final today = DateTime.now();
    return [
      for (var i = n - 1; i >= 0; i--) byDay[DateFormat('yyyy-MM-dd').format(DateTime(today.year, today.month, today.day - i))] ?? 0.0,
    ];
  }

  Map<int, String> _dayLabels({int n = 14}) {
    final today = DateTime.now();
    return {
      0: DateFormat('d MMM').format(DateTime(today.year, today.month, today.day - (n - 1))),
      (n ~/ 2) - 1: DateFormat('d MMM').format(DateTime(today.year, today.month, today.day - (n ~/ 2))),
      n - 1: 'Today',
    };
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return PushedPanel(kicker: 'Client', title: widget.name ?? 'Client', onRefresh: _load, children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    final c = Map<String, dynamic>.from(d['client']);
    final req = Map<String, dynamic>.from(d['requests']);
    final ai = Map<String, dynamic>.from(d['ai']);
    final week = Map<String, dynamic>.from(d['last_week']);
    final days = (req['days'] as List).cast<Map<String, dynamic>>();
    final lines = (ai['lines'] as List).cast<Map<String, dynamic>>();
    final aiDays = (ai['days'] as List).cast<Map<String, dynamic>>();
    final tutors = (d['tutors'] as List).cast<Map<String, dynamic>>();
    final classes = (d['classes'] as List).cast<Map<String, dynamic>>();
    final since = f.parseTime(c['created_at']);
    final seen = f.parseTime(c['last_active_at']);
    final online = seen != null && DateTime.now().difference(seen).inMinutes < 5;
    final pending = f.asInt(c['pending']);

    final perDay = _perDay(days, 'requests');
    final fortnight = perDay.fold<double>(0, (a, v) => a + v).round();
    final errorsAll = f.asInt(req['errors']);
    final countingSince = DateTime.tryParse('${req['counting_since']}');
    final todayRequests = perDay.last.round();
    final weekRequests = perDay.sublist(perDay.length - 7).fold<double>(0, (a, v) => a + v).round();
    final aiPerDay = _perDay(aiDays, 'cost_inr');
    final cost = f.asDouble(ai['cost_month_inr']);
    final callsMonth = f.asInt(ai['calls_month']);
    final failedMonth = f.asInt(ai['failed_month']);

    return PushedPanel(
      kicker: since == null ? 'Client' : 'Client · since ${DateFormat('d MMM y').format(since)}',
      title: '${c['name']}',
      onRefresh: _load,
      children: [
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (c['owner'] != null) TagChip('${c['owner']}'),
          TagChip(c['join_open'] == true ? 'Joining open' : 'Joining closed'),
          if (pending > 0) TagChip('$pending waiting to join', tone: Tone.warning),
          TagChip(seen == null ? 'Never used' : (online ? 'Online now' : 'Active ${f.ago(seen)}'), tone: online ? Tone.success : Tone.neutral),
        ]),
        const SizedBox(height: 18),
        StatGrid(
          label: 'Students',
          value: '${c['students']}',
          note: '${f.plural(f.asInt(c['groups']), 'group')}, ${f.plural(f.asInt(c['papers']), 'paper')} uploaded',
          small: [StatSmall('Tutors', '${c['tutors']}'), StatSmall('Tests', '${c['tests']}')],
        ),
        SectionRule('API requests', padding: _rule),
        Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Requests a day', style: labelStyle)),
              Fig('${f.count(fortnight)} in 14 days', style: labelStyle),
            ]),
            const SizedBox(height: 12),
            Bars(perDay, height: 44, labels: _dayLabels()),
          ]),
        ),
        const SizedBox(height: gapRow),
        FactList([
          ('Today', f.count(todayRequests)),
          ('Last 7 days', f.count(weekRequests)),
          ('Last 30 days', f.count(f.asInt(req['month']))),
          ('All counted', f.count(f.asInt(req['total']))),
          ('Errors, all counted', f.count(errorsAll)),
          if (countingSince != null) ('Counted since', f.dayLabel(countingSince.toLocal())),
        ]),
        SectionRule('AI work', padding: _rule),
        MeasurementCard(
          label: 'This month, at list prices',
          value: f.rupees(cost),
          unit: 'from ${f.plural(callsMonth, 'call')}',
          note: '${failedMonth > 0 ? '${f.plural(failedMonth, 'call')} failed. ' : ''}All time: ${f.rupees(f.asDouble(ai['cost_total_inr']))}.',
        ),
        const SizedBox(height: gapRow),
        Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Worth of AI work a day', style: labelStyle)),
              Fig(f.rupees(aiPerDay.fold<double>(0, (a, v) => a + v)), style: labelStyle),
            ]),
            const SizedBox(height: 12),
            Bars(aiPerDay, height: 44, labels: _dayLabels()),
          ]),
        ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: gapRow),
          for (final (i, l) in lines.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              title: _task('${l['task']}'),
              meta: [
                _model('${l['model']}'),
                f.plural(f.asInt(l['calls']), 'call'),
                if (f.asInt(l['failed']) > 0) '${f.asInt(l['failed'])} failed',
                '${f.tokens(f.asInt(l['tokens']))} tokens',
              ].join(' · '),
              trailing: Fig('${l['estimated'] == true ? '≈ ' : ''}${f.rupees(f.asDouble(l['cost_inr']))}', style: rowTitleStyle),
            ),
          ],
          if (lines.any((l) => l['estimated'] == true))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Fig('≈ marks a model that is not on the vendors\' price list, so its price is a guess.', style: labelStyle),
            ),
        ],
        SectionRule('Tutors', count: tutors.length, padding: _rule),
        for (final (i, t) in tutors.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          RowTile(
            leading: AppAvatar(name: '${t['display_name']}', seed: '${t['username']}'),
            title: '${t['display_name']}',
            meta: '${t['role'] == 'owner' ? 'Owner' : 'Tutor'} · ${t['username']} · ${t['last_seen_at'] == null ? 'never used' : f.ago(f.parseTime(t['last_seen_at']))}',
          ),
        ],
        if (classes.isNotEmpty) ...[
          SectionRule('Classes', count: classes.length, padding: _rule),
          FactList([
            for (final x in classes)
              (
                x['label'] != null ? '${x['label']}' : 'Class ${x['class_level']}',
                f.plural(f.asInt(x['students']), 'student'),
              ),
          ]),
        ],
        SectionRule('Last 7 days', padding: _rule),
        FactList([
          ('Papers uploaded', f.count(f.asInt(week['papers']))),
          ('Tests made', f.count(f.asInt(week['tests']))),
          ('Tests written', f.count(f.asInt(week['attempts']))),
        ]),
        const SizedBox(height: 8),
      ],
    );
  }
}
