import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/auto_refresh.dart';
import '../core/format.dart' as f;
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';
import 'client.dart';

enum _Sort { active, requests, cost, students, newest }

const _sortLabels = {
  _Sort.active: 'Last active',
  _Sort.requests: 'Most requests, 30 days',
  _Sort.cost: 'Most AI spend this month',
  _Sort.students: 'Most students',
  _Sort.newest: 'Newest',
};

/// The clients: every tuition on the service, how big it is, how much it uses the API and what its
/// AI use would cost at list prices. Students are only ever counted here, never named.
class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});

  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> with WidgetsBindingObserver, AutoRefresh<ClientsScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  _Sort _sort = _Sort.active;

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
      final d = await api.get('/admin/clients');
      if (!mounted) return;
      markLoaded();
      setState(() {
        _d = Map<String, dynamic>.from(d);
        _error = null;
      });
    } on ApiException catch (e) {
      // A later load that fails keeps what is shown; only the first one has nothing to fall back on.
      if (mounted && _d == null) setState(() => _error = e.message);
    }
  }

  int _int(Map<String, dynamic> c, String a, [String? b]) => f.asInt(b == null ? c[a] : (c[a] as Map)[b]);

  List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> rows) {
    final list = [...rows];
    int when(Map<String, dynamic> c, String key) => f.parseTime(c[key])?.millisecondsSinceEpoch ?? 0;
    switch (_sort) {
      case _Sort.active:
        list.sort((a, b) => when(b, 'last_active_at').compareTo(when(a, 'last_active_at')));
      case _Sort.requests:
        list.sort((a, b) => _int(b, 'requests', 'month').compareTo(_int(a, 'requests', 'month')));
      case _Sort.cost:
        list.sort((a, b) => f.asDouble((b['ai'] as Map)['cost_month_inr']).compareTo(f.asDouble((a['ai'] as Map)['cost_month_inr'])));
      case _Sort.students:
        list.sort((a, b) => _int(b, 'students').compareTo(_int(a, 'students')));
      case _Sort.newest:
        list.sort((a, b) => when(b, 'created_at').compareTo(when(a, 'created_at')));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final totals = d == null ? null : Map<String, dynamic>.from(d['totals']);
    return PullToRefresh(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
        TabHeader(
          kicker: totals == null ? 'Tuitions on the service' : '${f.plural(f.asInt(totals['clients']), 'client')} · ${f.asInt(totals['active_week'])} active this week',
          title: 'Clients',
        ),
        if (d == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (d == null)
          const LoadingState(inset: true)
        else
          ..._body(d, totals!),
        navClearance,
      ]),
    );
  }

  List<Widget> _body(Map<String, dynamic> d, Map<String, dynamic> t) {
    final clients = (d['clients'] as List).cast<Map<String, dynamic>>();
    final since = DateTime.tryParse('${d['counting_since']}');
    final unattributed = f.asDouble(t['ai_cost_unattributed_month_inr']);
    final cost = f.asDouble(t['ai_cost_month_inr']);
    final shown = _sorted(clients);

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
        child: StatGrid(
          label: 'Clients',
          value: '${t['clients']}',
          note: f.asInt(t['active_week']) == 0 ? 'None used the app in the last 7 days' : '${t['active_week']} used the app in the last 7 days',
          small: [StatSmall('Students', f.count(f.asInt(t['students']))), StatSmall('Requests today', f.count(f.asInt(t['requests_today'])))],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, gapRow, gutter, 0),
        child: MeasurementCard(
          label: 'AI work this month, at list prices',
          value: f.rupees(cost),
          unit: 'from ${f.plural(f.asInt(t['ai_calls_month']), 'call')}',
          note: 'Worked out from the tokens used, at Google\'s and Groq\'s list prices (₹${d['usd_inr']} to the dollar). '
              'It is what this work would cost on a paid plan, not a bill.'
              '${unattributed >= 0.005 ? ' ${f.rupees(unattributed)} of it belongs to no client.' : ''}',
        ),
      ),
      SectionRule('All clients', count: clients.length),
      if (clients.length > 1)
        FilterBar(children: [
          SelectPill(
            label: _sortLabels[_sort]!,
            active: _sort != _Sort.active,
            onTap: () async {
              final c = await showChoices<_Sort>(
                context,
                title: 'Order by',
                options: [for (final s in _Sort.values) Choice(s, _sortLabels[s]!)],
                selected: _sort,
              );
              if (c?.value != null) setState(() => _sort = c!.value!);
            },
          ),
        ]),
      if (clients.length > 1) const SizedBox(height: gapRow),
      if (clients.isEmpty)
        EmptyState(icon: Ph.buildings, title: 'No clients yet', body: 'A tuition shows here from the day a tutor signs up and creates it.')
      else
        Rows([for (final c in shown) _row(c)]),
      if (clients.isNotEmpty) ...[
        const SectionRule('All clients together'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          child: FactList([
            ('Tutors', f.count(f.asInt(t['tutors']))),
            ('API requests, 30 days', f.count(f.asInt(t['requests_month']))),
            ('Requests counted since', since == null ? 'not yet' : f.dayLabel(since.toLocal())),
          ]),
        ),
      ],
    ];
  }

  Widget _row(Map<String, dynamic> c) {
    final ai = Map<String, dynamic>.from(c['ai']);
    final requests = Map<String, dynamic>.from(c['requests']);
    final students = f.asInt(c['students']);
    final pending = f.asInt(c['pending']);
    final seen = f.parseTime(c['last_active_at']);
    return RowTile(
      leading: AppAvatar(name: '${c['name']}', seed: '${c['id']}'),
      title: '${c['name']}',
      // Two lines, so the break never falls in the middle of a fact.
      meta: [
        [if (c['owner'] != null) '${c['owner']}', f.plural(students, 'student'), if (pending > 0) '$pending waiting'].join(' · '),
        seen == null ? 'Never used' : 'Active ${f.ago(seen)}',
      ].join('\n'),
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Fig(f.rupees(f.asDouble(ai['cost_month_inr'])), style: rowTitleStyle),
        const SizedBox(height: 2),
        Fig('${f.count(f.asInt(requests['month']))} requests', style: labelStyle),
      ]),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ClientScreen(id: '${c['id']}', name: '${c['name']}')));
        if (mounted) _load();
      },
    );
  }
}
