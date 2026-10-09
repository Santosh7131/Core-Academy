import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';
import 'account.dart';

enum _Kind { all, login, test, ai, error }

const _kindLabels = {_Kind.all: 'Everything', _Kind.login: 'Logins', _Kind.test: 'Tests and papers', _Kind.ai: 'AI reader', _Kind.error: 'Server errors'};

/// What happened, newest first: logins, tests written, papers uploaded, AI reads, server errors.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  List<Map<String, dynamic>>? _events;
  String? _error;
  bool _more = true;
  bool _loadingMore = false;
  _Kind _kind = _Kind.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await api.get('/admin/log');
      if (!mounted) return;
      setState(() {
        _events = (r['events'] as List).cast<Map<String, dynamic>>();
        _more = _events!.length >= 80;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _older() async {
    final last = _events?.lastOrNull;
    if (last == null) return;
    setState(() => _loadingMore = true);
    try {
      final r = await api.get('/admin/log?before=${Uri.encodeQueryComponent('${last['at']}')}');
      final more = (r['events'] as List).cast<Map<String, dynamic>>();
      if (mounted) {
        setState(() {
          _events = [...?_events, ...more];
          _more = more.length >= 80;
        });
      }
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Events in day groups, newest day first: ("Today", [...]), ("Yesterday", [...]), ...
  List<(String, List<Map<String, dynamic>>)> _byDay(List<Map<String, dynamic>> events) {
    final groups = <(String, List<Map<String, dynamic>>)>[];
    for (final e in events) {
      final t = f.parseTime(e['at']);
      final label = t == null ? 'Unknown day' : f.dayLabel(t);
      if (groups.isEmpty || groups.last.$1 != label) groups.add((label, []));
      groups.last.$2.add(e);
    }
    return groups;
  }

  bool _matches(Map<String, dynamic> e, _Kind k) => k == _Kind.all || e['kind'] == k.name || (k == _Kind.test && e['kind'] == 'paper');

  @override
  Widget build(BuildContext context) {
    final events = _events;
    final shown = events?.where((e) => _matches(e, _kind)).toList();
    return PullToRefresh(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
        const TabHeader(kicker: 'Newest first', title: 'Log'),
        const SizedBox(height: 18),
        FilterBar(children: [
          SelectPill(
            label: _kindLabels[_kind]!,
            count: shown?.length,
            active: _kind != _Kind.all,
            onTap: () async {
              final c = await showChoices<_Kind>(
                context,
                title: 'Show',
                options: [for (final k in _Kind.values) Choice(k, _kindLabels[k]!, count: events?.where((e) => _matches(e, k)).length)],
                selected: _kind,
              );
              if (c?.value != null) setState(() => _kind = c!.value!);
            },
          ),
        ]),
        if (events == null || shown!.isEmpty) const SizedBox(height: 16),
        if (events == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (events == null)
          const LoadingState()
        else if (shown!.isEmpty)
          EmptyState(icon: Ph.listBullets, title: 'Nothing here yet', body: 'Logins, tests, papers, AI reads and errors show up here as they happen.')
        else
          for (final (label, group) in _byDay(shown)) ...[
            SectionRule(label, count: group.length),
            Rows([for (final e in group) _row(e)]),
          ],
        if (events != null && _more)
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 0),
            child: SecondaryButton(_loadingMore ? 'Loading' : 'Older', onTap: _loadingMore ? null : _older),
          ),
        navClearance,
      ]),
    );
  }

  Widget _row(Map<String, dynamic> e) {
    final kind = '${e['kind']}';
    final what = '${e['what']}';
    final who = '${e['who'] ?? ''}';
    final (IconData icon, Color fg, Color bgc, String title, String meta) = switch (kind) {
      'login' => (
          what == 'ok' || what == 'signup' ? Ph.key : Ph.lockKey,
          what == 'ok' || what == 'signup' ? success : danger,
          what == 'ok' || what == 'signup' ? successSoft : dangerSoft,
          switch (what) {
            'ok' => '$who logged in',
            'signup' => '$who signed up as a tutor',
            'wrong_secret' => '$who: wrong PIN or password',
            'lockout' => '$who locked after 5 wrong tries',
            'locked' => '$who tried while locked',
            'inactive' => '$who tried while turned off',
            'unknown_user' => 'Unknown username "$who"',
            _ => '$who: $what',
          },
          [if (e['detail'] != null) '${e['detail']}', if (e['extra'] != null) '${e['extra']}'].join(' · '),
        ),
      'test' => (Ph.exam, ink, fill, '$who ${what == 'auto' ? 'ran out of time on' : 'wrote'} ${e['detail']}', '${e['extra']} marks'),
      'paper' => (Ph.fileText, ink, fill, '$who uploaded ${e['detail']}', '${e['extra']}'),
      'ai' => (
          Ph.scan,
          what == 'ok' ? aiAccent : warning,
          what == 'ok' ? aiAccentSoft : warningSoft,
          'AI ${who.replaceAll('_', ' ')} ${what == 'ok' ? 'done' : 'failed'}',
          [if ('${e['detail']}'.isNotEmpty) '${e['detail']}', '${e['extra']}'].join(' · '),
        ),
      'error' => (Ph.bug, danger, dangerSoft, '$what · $who', '${e['detail']}'),
      _ => (Ph.circle, muted, fill, '$kind $what', who),
    };
    final userId = e['user_id'];
    final at = f.parseTime(e['at']);
    return RowTile(
      leading: Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: bgc, shape: BoxShape.circle),
        child: Icon(icon, size: 16, color: fg),
      ),
      title: title,
      meta: meta.isEmpty ? null : meta,
      trailing: Fig(at == null ? '-' : f.time(at), style: labelStyle),
      onTap: userId == null || kind == 'ai' || kind == 'error'
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountScreen(id: '$userId'))),
    );
  }
}
