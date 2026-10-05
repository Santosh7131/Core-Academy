import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/github.dart';
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';
import 'account.dart';

enum _Show { all, online, flagged, quiet }

const _showLabels = {_Show.all: 'Everyone', _Show.online: 'Online now', _Show.flagged: 'Flagged', _Show.quiet: 'Not seen in 7 days'};

/// Every account, like the main app's Students tab: who it is, when it was last seen, its phones.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key});

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  List<Map<String, dynamic>>? _rows;
  int _many = 3;
  String? _newest;
  String? _error;
  _Show _show = _Show.all;
  int? _class;
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/admin/people');
      if (!mounted) return;
      setState(() {
        _rows = (r['people'] as List).cast<Map<String, dynamic>>();
        _many = f.asInt(r['many_threshold']);
        _error = null;
      });
      newestVersion().then((v) {
        if (mounted && v != null) setState(() => _newest = v);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  bool _online(Map<String, dynamic> p) {
    final t = f.parseTime(p['last_seen_at']);
    return t != null && DateTime.now().difference(t).inMinutes < 5;
  }

  bool _flagged(Map<String, dynamic> p) => p['locked'] == true || p['active'] != true || f.asInt(p['phones']) >= _many;

  bool _quiet(Map<String, dynamic> p) {
    final t = f.parseTime(p['last_seen_at']);
    return t == null || DateTime.now().difference(t).inDays >= 7;
  }

  bool _matches(Map<String, dynamic> p, _Show s) => switch (s) {
        _Show.all => true,
        _Show.online => _online(p),
        _Show.flagged => _flagged(p),
        _Show.quiet => _quiet(p),
      };

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final q = _search.text.trim().toLowerCase();
    final inClass = rows?.where((p) => _class == null || p['class_level'] == _class).toList();
    final shown = inClass
        ?.where((p) => _matches(p, _show) && (q.isEmpty || '${p['display_name']}'.toLowerCase().contains(q) || '${p['username']}'.contains(q)))
        .toList();
    final phones = rows?.fold<int>(0, (a, p) => a + f.asInt(p['phones'])) ?? 0;
    final classes = {for (final p in rows ?? const <Map<String, dynamic>>[]) if (p['class_level'] != null) f.asInt(p['class_level'])}.toList()..sort();

    // Seen today, this week, earlier, never.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    String bucket(Map<String, dynamic> p) {
      final t = f.parseTime(p['last_seen_at']);
      if (t == null) return 'Never logged in';
      if (!t.isBefore(today)) return 'Seen today';
      if (now.difference(t).inDays < 7) return 'Seen this week';
      return 'Not seen in 7 days';
    }

    final groups = <String, List<Map<String, dynamic>>>{};
    for (final p in shown ?? const <Map<String, dynamic>>[]) {
      groups.putIfAbsent(bucket(p), () => []).add(p);
    }

    return PullToRefresh(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
        TabHeader(
          kicker: rows == null ? 'Accounts' : '${f.plural(rows.length, 'account')} · ${f.plural(phones, 'phone')}',
          title: 'People',
        ),
        const SizedBox(height: 18),
        FilterBar(children: [
          SelectPill(
            label: _showLabels[_show]!,
            count: inClass?.where((p) => _matches(p, _show)).length,
            active: _show != _Show.all,
            onTap: () async {
              final c = await showChoices<_Show>(
                context,
                title: 'Show',
                options: [for (final s in _Show.values) Choice(s, _showLabels[s]!, count: inClass?.where((p) => _matches(p, s)).length)],
                selected: _show,
              );
              if (c?.value != null) setState(() => _show = c!.value!);
            },
          ),
          SelectPill(
            label: _class == null ? 'All classes' : 'Class $_class',
            active: _class != null,
            onTap: () async {
              final c = await showChoices<int>(
                context,
                title: 'Class',
                options: [const Choice(null, 'All classes'), for (final c in classes) Choice(c, 'Class $c')],
                selected: _class,
              );
              if (c != null) setState(() => _class = c.value);
            },
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(gutter, 10, gutter, 0),
          child: GroupedInputs(children: [
            BareField(controller: _search, placeholder: 'Search name or username', onChanged: (_) => setState(() {})),
          ]),
        ),
        if (rows == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (rows == null)
          const LoadingState()
        else if (shown!.isEmpty)
          EmptyState(icon: Ph.users, title: 'Nobody here', body: 'No account matches these filters.')
        else
          for (final g in ['Seen today', 'Seen this week', 'Not seen in 7 days', 'Never logged in'])
            if (groups[g] != null) ...[
              SectionRule(g, count: groups[g]!.length),
              Rows([for (final p in groups[g]!) _row(p)]),
            ],
        navClearance,
      ]),
    );
  }

  Widget _row(Map<String, dynamic> p) {
    final phones = f.asInt(p['phones']);
    final who = p['role'] == 'teacher' ? 'Teacher' : 'Class ${p['class_level']}';
    final version = p['app_version'] as String? ?? (p['on_old_app'] == true ? 'older' : null);
    final Widget flag;
    if (p['active'] != true) {
      flag = const TagChip('Turned off', tone: Tone.danger);
    } else if (p['locked'] == true) {
      flag = const TagChip('Locked', tone: Tone.danger);
    } else if (phones >= _many) {
      flag = TagChip('$phones phones', tone: Tone.warning);
    } else {
      flag = versionTag(version, _newest);
    }
    final showPhones = phones > 0 && phones < _many;
    return RowTile(
      leading: AppAvatar(name: '${p['display_name']}', seed: '${p['id']}'),
      title: '${p['display_name']}',
      meta: '$who · ${p['username']} · ${p['last_seen_at'] == null ? 'never' : f.ago(f.parseTime(p['last_seen_at']))}',
      trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        flag,
        if (showPhones) ...[const SizedBox(height: 4), Fig(f.plural(phones, 'phone'), style: labelStyle)],
      ]),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountScreen(id: '${p['id']}')));
        _load();
      },
    );
  }
}
