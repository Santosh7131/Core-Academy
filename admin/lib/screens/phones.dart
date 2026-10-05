import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/github.dart';
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';
import 'account.dart';

enum _Show { all, shared, admin }

const _showLabels = {_Show.all: 'Core Academy app', _Show.shared: 'Shared phones', _Show.admin: 'Admin app'};

/// Every installed copy of the apps: its model, Android and app version, and who uses it.
class PhonesScreen extends StatefulWidget {
  const PhonesScreen({super.key});

  @override
  State<PhonesScreen> createState() => _PhonesScreenState();
}

class _PhonesScreenState extends State<PhonesScreen> {
  List<Map<String, dynamic>>? _phones;
  List<Map<String, dynamic>> _old = [];
  String? _newest;
  String? _error;
  _Show _show = _Show.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/admin/phones');
      if (!mounted) return;
      setState(() {
        _phones = (r['phones'] as List).cast<Map<String, dynamic>>();
        _old = (r['old_app_sessions'] as List).cast<Map<String, dynamic>>();
        _error = null;
      });
      newestVersion().then((v) {
        if (mounted && v != null) setState(() => _newest = v);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  List<Map<String, dynamic>> _accounts(Map<String, dynamic> p) => (p['accounts'] as List).cast<Map<String, dynamic>>();

  List<Map<String, dynamic>>? _of(_Show s) => _phones?.where((p) => switch (s) {
        _Show.all => p['app'] == 'core_academy',
        _Show.shared => p['app'] == 'core_academy' && _accounts(p).length > 1,
        _Show.admin => p['app'] == 'admin',
      }).toList();

  @override
  Widget build(BuildContext context) {
    final shown = _of(_show);
    final oldCount = _old.fold<int>(0, (a, s) => a + f.asInt(s['sessions']));
    return PullToRefresh(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
        TabHeader(
          kicker: _phones == null ? 'Phones' : '${f.plural(_of(_Show.all)!.length, 'phone')} known · ${f.plural(oldCount, 'older app')}',
          title: 'Phones',
        ),
        const SizedBox(height: 18),
        FilterBar(children: [
          SelectPill(
            label: _showLabels[_show]!,
            count: shown?.length,
            active: _show != _Show.all,
            onTap: () async {
              final c = await showChoices<_Show>(
                context,
                title: 'Show',
                options: [for (final s in _Show.values) Choice(s, _showLabels[s]!, count: _of(s)?.length)],
                selected: _show,
              );
              if (c?.value != null) setState(() => _show = c!.value!);
            },
          ),
        ]),
        if (_phones == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (_phones == null)
          const LoadingState()
        else ...[
          SectionRule(switch (_show) { _Show.all => 'Known phones', _Show.shared => 'Used by more than one account', _Show.admin => 'Admin app' },
              count: shown!.length),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              child: Text(
                switch (_show) {
                  _Show.all => 'No phone has reported itself yet. Phones start to once they run app 1.2.1.',
                  _Show.shared => 'No phone is shared between accounts.',
                  _Show.admin => 'None yet.',
                },
                style: bodyStyle.copyWith(color: muted),
              ),
            )
          else
            Rows([for (final p in shown) _row(p)]),
          if (_show == _Show.all && _old.isNotEmpty) ...[
            SectionRule('On app 1.2.0 or older', count: oldCount),
            Rows([
              for (final s in _old)
                RowTile(
                  leading: AppAvatar(name: '${s['display_name']}', seed: '${s['id']}'),
                  title: '${s['display_name']}',
                  meta: '${f.plural(f.asInt(s['sessions']), 'phone')} · last used ${f.ago(f.parseTime(s['last_used_at']))}',
                  trailing: const TagChip('Older app'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountScreen(id: '${s['id']}'))),
                ),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 10, gutter, 0),
              child: Fig('Older apps do not say which phone they are on; each login counts as one phone until it updates.', style: labelStyle),
            ),
          ],
        ],
        navClearance,
      ]),
    );
  }

  Widget _row(Map<String, dynamic> p) {
    final accounts = _accounts(p);
    final names = accounts.map((a) => '${a['display_name']}').join(', ');
    return RowTile(
      leading: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        child: Icon(Ph.deviceMobile, size: 17, color: ink),
      ),
      title: '${p['model'] ?? 'Unknown phone'}',
      meta: '${'${p['os_version'] ?? ''}'.split(' (').first} · ${names.isEmpty ? 'no account' : names} · ${f.ago(f.parseTime(p['last_seen_at']))}',
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (p['app_version'] != null) p['app'] == 'admin' ? TagChip('${p['app_version']}') : versionTag('${p['app_version']}', _newest),
        if (accounts.length > 1) ...[const SizedBox(height: 4), TagChip('${accounts.length} accounts', tone: Tone.warning)],
      ]),
      onTap: accounts.isEmpty
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountScreen(id: '${accounts.first['id']}'))),
    );
  }
}
