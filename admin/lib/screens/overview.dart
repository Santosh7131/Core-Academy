import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/api.dart';
import '../core/auto_refresh.dart';
import '../core/format.dart' as f;
import '../core/github.dart';
import '../core/session.dart';
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';
import 'account.dart';
import 'phones.dart';
import 'settings.dart';
import 'shell.dart';
import 'update_card.dart';

/// The admin app's Home: who is using the app now, the clients, the month's compute, versions, today, alerts.
class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> with WidgetsBindingObserver, AutoRefresh<OverviewScreen> {
  Map<String, dynamic>? _d;
  String? _newest;
  String? _error;

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
    try {
      final d = await api.get('/admin/overview');
      if (!mounted) return;
      markLoaded();
      setState(() {
        _d = Map<String, dynamic>.from(d);
        _error = null;
      });
      newestVersion().then((v) {
        if (mounted && v != null) setState(() => _newest = v);
      });
    } on ApiException catch (e) {
      // A later load that fails keeps what is shown; only the first one has nothing to fall back on.
      if (mounted && _d == null) setState(() => _error = e.message);
    }
  }

  void _openPhones() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PhonesScreen()));

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return PullToRefresh(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
        TabHeader(
          kicker: 'Admin · ${DateFormat('d MMMM').format(DateTime.now())}',
          title: 'Overview',
          actions: [
            Pressable(
              label: 'Settings',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
              child: AppAvatar(name: '${session.user?['display_name'] ?? 'Developer'}', seed: '${session.user?['id'] ?? ''}', size: 40),
            ),
          ],
        ),
        const UpdateBanner(),
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
    final people = Map<String, dynamic>.from(d['people']);
    final today = Map<String, dynamic>.from(d['today']);
    final compute = Map<String, dynamic>.from(d['compute']);
    final services = Map<String, dynamic>.from(d['services']);
    final clients = Map<String, dynamic>.from(d['clients'] ?? const {});
    final aiCost = Map<String, dynamic>.from(d['ai_cost'] ?? const {});
    final versions = (d['versions'] as List).cast<Map<String, dynamic>>();
    final alerts = (d['alerts'] as List).cast<Map<String, dynamic>>();
    final cu = f.asDouble(compute['cu_hours']);
    final freeCu = f.asDouble(compute['free_cu_hours']);
    final projected = compute['projected_cu_hours'];
    final since = f.parseTime(compute['counting_since']);
    final resets = f.parseTime(compute['resets_at']);
    final clientCount = f.asInt(clients['total']);
    final newClients = f.asInt(clients['new_week']);

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          if (api.lastMs != null) TagChip('API ${api.lastMs} ms'),
          TagChip(services['ai'] == true ? 'AI reader on' : 'AI reader off', tone: services['ai'] == true ? Tone.success : Tone.neutral),
          TagChip(services['push'] == true ? 'Push on' : 'Push not set up'),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
        child: StatGrid(
          label: 'Active now',
          value: '${people['active_now']}',
          note: 'in the last 5 minutes, of ${people['accounts']} accounts',
          small: [StatSmall('Seen today', '${people['today']}'), StatSmall('This week', '${people['week']}')],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, gapRow, gutter, 0),
        child: Pressable(
          label: 'Compute this month',
          onTap: () => Shell.go(context, Shell.server),
          child: MeasurementCard(
            label: 'Compute this month, estimated',
            value: cu.toStringAsFixed(1),
            unit: 'of ${freeCu.round()} CU-h',
            fraction: freeCu <= 0 ? 0 : cu / freeCu,
            valueColor: cu / freeCu > 0.8 ? warning : null,
            note: projected == null
                ? 'Counting since ${f.when(since)}; a projection comes after a day. Neon\'s console has the exact figure.'
                : 'On track for ${f.asDouble(projected).round()} CU-h by ${f.clock(resets)}. Neon\'s console has the exact figure.',
          ),
        ),
      ),
      SectionRule('Clients', count: clientCount),
      Rows([
        RowTile(
          leading: Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
            child: Icon(Ph.buildings, size: 17, color: ink),
          ),
          title: f.plural(clientCount, 'client'),
          meta: '${f.asInt(clients['active_week'])} active this week${newClients > 0 ? ' · $newClients new' : ''}',
          trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Fig(f.rupees(f.asDouble(aiCost['month_inr'])), style: rowTitleStyle),
            const SizedBox(height: 2),
            Fig('AI this month', style: labelStyle),
          ]),
          chevron: true,
          onTap: () => Shell.go(context, Shell.clients),
        ),
      ]),
      SectionRule('App versions', count: versions.fold<int>(0, (a, v) => a + f.asInt(v['phones']))),
      if (versions.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(horizontal: gutter), child: Text('No phone has been used this week.', style: bodyStyle.copyWith(color: muted)))
      else
        Rows([
          for (final v in versions)
            RowTile(
              title: switch (v['version']) { 'older' => 'App 1.2.0 or older', 'unknown' => 'Version not known', final x => 'App $x' },
              meta: switch (v['version']) {
                'older' => 'These do not say which phone they are on yet',
                'unknown' => 'These phones did not send a version',
                _ when _newest == null => 'Used this week',
                final x => x == _newest ? 'The newest release' : 'Behind the newest release',
              },
              trailing: Fig('${v['phones']} phone${f.asInt(v['phones']) == 1 ? '' : 's'}', style: rowTitleStyle),
              onTap: _openPhones,
            ),
        ]),
      const SectionRule('Today'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        child: FactList([
          ('Tests written', '${today['tests_written']}'),
          ('Writing now', '${today['writing_now']}'),
          ('Logins', f.count(f.asInt(today['logins']))),
          ('Wrong PINs, lockouts', '${today['wrong_secrets']}, ${today['lockouts']}'),
          ('API requests, errors', '${f.count(f.asInt(today['requests']))}, ${today['errors']}'),
          ('AI reads, failed', '${today['ai_calls']}, ${today['ai_failed']}'),
          if (aiCost['today_inr'] != null) ('AI work, at list prices', f.rupees(f.asDouble(aiCost['today_inr']))),
        ]),
      ),
      SectionRule('Needs a look', count: alerts.length, alert: alerts.isNotEmpty),
      if (alerts.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(horizontal: gutter), child: Text('Nothing needs a look.', style: bodyStyle.copyWith(color: muted)))
      else
        Rows([
          for (final a in alerts)
            RowTile(
              leading: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: a['kind'] == 'phones' ? warningSoft : dangerSoft, shape: BoxShape.circle),
                child: Icon(
                  switch (a['kind']) { 'phones' => Ph.deviceMobile, 'locked' => Ph.lockKey, 'errors' => Ph.bug, _ => Ph.robot },
                  size: 17,
                  color: a['kind'] == 'phones' ? warning : danger,
                ),
              ),
              title: '${a['title']}',
              meta: '${a['detail']}${a['at'] == null ? '' : ' · ${f.ago(f.parseTime(a['at']))}'}',
              chevron: true,
              onTap: () {
                if (a['user_id'] != null) {
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountScreen(id: '${a['user_id']}')));
                } else {
                  Shell.go(context, a['kind'] == 'errors' ? Shell.server : Shell.log);
                }
              },
            ),
        ]),
    ];
  }
}
