import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/api.dart';
import '../core/auto_refresh.dart';
import '../core/format.dart' as f;
import '../core/github.dart';
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';

/// Neon: compute (estimated), database and storage, the API's requests and errors, and services.
class ServerScreen extends StatefulWidget {
  const ServerScreen({super.key});

  @override
  State<ServerScreen> createState() => _ServerScreenState();
}

class _ServerScreenState extends State<ServerScreen> with WidgetsBindingObserver, AutoRefresh<ServerScreen> {
  Map<String, dynamic>? _d;
  List<AppRelease>? _releases;
  String? _error;

  @override
  Duration? get pollEvery => const Duration(seconds: 120);

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.get('/admin/server');
      if (!mounted) return;
      markLoaded();
      setState(() {
        _d = Map<String, dynamic>.from(d);
        _error = null;
      });
      appReleases().then((r) {
        if (mounted && r != null) setState(() => _releases = r);
      });
    } on ApiException catch (e) {
      if (mounted && _d == null) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return PullToRefresh(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
        TabHeader(
          kicker: d == null ? 'Neon' : 'Neon · ${d['branch']} · Postgres ${'${d['database']['version']}'.split(' ').first}',
          title: 'Server',
        ),
        if (d == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (d == null)
          const LoadingState(inset: true)
        else
          ..._body(d),
        navClearance,
      ]),
    );
  }

  List<Widget> _body(Map<String, dynamic> d) {
    final compute = Map<String, dynamic>.from(d['compute']);
    final db = Map<String, dynamic>.from(d['database']);
    final storage = Map<String, dynamic>.from(d['storage']);
    final apiStats = Map<String, dynamic>.from(d['api']);
    final ai = Map<String, dynamic>.from(d['ai']);
    final push = Map<String, dynamic>.from(d['push']);
    final now = DateTime.now().toUtc();
    final daysInMonth = DateTime.utc(now.year, now.month + 1, 0).day;
    final byDay = {for (final x in (compute['days'] as List)) '${x['day']}': f.asDouble(x['cu_hours'])};
    final perDay = [
      for (var day = 1; day <= daysInMonth; day++)
        byDay['${now.year}-${'${now.month}'.padLeft(2, '0')}-${'$day'.padLeft(2, '0')}'] ?? 0.0,
    ];
    final usedDays = perDay.where((v) => v > 0).length;
    final cu = f.asDouble(compute['cu_hours']);
    final freeCu = f.asDouble(compute['free_cu_hours']);
    final days = (apiStats['days'] as List).cast<Map<String, dynamic>>();
    final byApiDay = {for (final x in days) '${x['day']}': f.asDouble(x['requests'])};
    final today = DateTime.now();
    final fortnight = [
      for (var i = 13; i >= 0; i--) byApiDay[DateTime(today.year, today.month, today.day - i).toIso8601String().substring(0, 10)] ?? 0.0,
    ];
    final routes = (apiStats['routes'] as List).cast<Map<String, dynamic>>();
    final errors = (apiStats['errors'] as List).cast<Map<String, dynamic>>();
    final tables = (db['tables'] as List).cast<Map<String, dynamic>>();
    final groups = (storage['groups'] as List).cast<Map<String, dynamic>>();
    final latest = _releases?.isNotEmpty == true ? _releases!.first : null;
    final requests = days.fold<int>(0, (a, x) => a + f.asInt(x['requests']));
    final errorCount = days.fold<int>(0, (a, x) => a + f.asInt(x['errors']));

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
        child: MeasurementCard(
          label: 'Compute this month, estimated',
          value: cu.toStringAsFixed(1),
          unit: 'of ${freeCu.round()} CU-h',
          fraction: freeCu <= 0 ? 0 : cu / freeCu,
          note: usedDays == 0
              ? 'Counted from when the database woke and its last request. Neon\'s console has the exact figure.'
              : 'About ${(cu / usedDays).toStringAsFixed(1)} CU-h a day, counted from when the database woke and its last request.',
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, gapRow, gutter, 0),
        child: Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Compute by day', style: labelStyle),
            const SizedBox(height: 12),
            Bars(perDay, labels: {for (final day in [1, 8, 15, 22, daysInMonth]) day - 1: '$day'}),
          ]),
        ),
      ),
      const SectionRule('Size'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: FactList([
          ('Database', '${f.bytes(f.asInt(db['bytes']))} of ${f.bytes(f.asInt(db['limit_bytes'])).replaceFirst('.00 ', ' ')}'),
          ('Storage', '${f.bytes(f.asInt(storage['bytes']))}, ${f.plural(f.asInt(storage['files']), 'file')}'),
        ]),
      ),
      const SectionRule('API, 14 days'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: Surface(
          shadow: e1,
          padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('Requests a day', style: labelStyle)),
              Fig('${f.count(requests)} in all, ${f.plural(errorCount, 'error')}', style: labelStyle.copyWith(color: errorCount > 0 ? danger : muted)),
            ]),
            const SizedBox(height: 12),
            Bars(fortnight, height: 44, labels: {
              0: DateFormat('d MMM').format(DateTime(today.year, today.month, today.day - 13)),
              6: DateFormat('d MMM').format(DateTime(today.year, today.month, today.day - 7)),
              13: 'Today',
            }),
          ]),
        ),
      ),
      if (routes.isNotEmpty) ...[
        const SizedBox(height: gapRow),
        Rows([
          for (final r in routes.take(6))
            RowTile(
              title: '${r['route']}',
              meta: '${f.plural(f.asInt(r['requests']), 'request')} · slowest ${f.asInt(r['max_ms'])} ms',
              trailing: Fig('${f.asInt(r['avg_ms'])} ms', style: rowTitleStyle),
            ),
        ]),
      ],
      SectionRule('Server errors, 30 days', count: errors.length, alert: errors.isNotEmpty),
      if (errors.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(horizontal: gutter), child: Text('No server errors.', style: bodyStyle.copyWith(color: muted)))
      else
        Rows([
          for (final e in errors.take(10))
            RowTile(
              title: '${e['status']} · ${e['method']} ${e['route']}',
              meta: '${e['message'] ?? ''}',
              metaColor: danger,
              trailing: Fig(f.ago(f.parseTime(e['at'])), style: labelStyle),
            ),
        ]),
      const SectionRule('Database tables'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: FactList([for (final t in tables.take(8)) ('${t['name']}', '${f.bytes(f.asInt(t['bytes']))}, ${f.count(f.asInt(t['rows']))} rows')]),
      ),
      const SectionRule('Storage'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: groups.isEmpty
            ? Text('Empty.', style: bodyStyle.copyWith(color: muted))
            : FactList([
                for (final g in groups)
                  (
                    switch ('${g['name']}') {
                      'papers' => 'Question paper pages',
                      'questions' => 'Question images',
                      'notify' => 'Notification schedule',
                      'admin' => 'Admin app',
                      _ => '${g['name']}',
                    },
                    '${f.bytes(f.asInt(g['bytes']))}, ${f.plural(f.asInt(g['files']), 'file')}',
                  ),
              ]),
      ),
      const SectionRule('Services'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: FactList([
          ('AI reader', ai['configured'] == true ? '${ai['today']} today, ${ai['failed_today']} failed' : 'No Groq keys'),
          if (ai['configured'] == true) ('AI, 7 days', '${ai['week']} reads, ${f.asInt(ai['avg_ms'])} ms'),
          ('Push', push['configured'] == true ? '${push['tokens']} phones registered' : 'Not set up'),
          ('Latest release', latest == null ? 'GitHub not reached' : '${latest.version}, ${f.plural(latest.downloads, 'download')}'),
          if (_releases != null)
            for (final r in _releases!.skip(1).take(3)) ('Release ${r.version}', f.plural(r.downloads, 'download')),
        ]),
      ),
    ];
  }
}
