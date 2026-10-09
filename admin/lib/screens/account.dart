import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart' as f;
import '../core/github.dart';
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';

const _rule = EdgeInsets.fromLTRB(0, 26, 0, 11);

/// One account, as a pushed panel like the main app's student page: its phones, logins and tests.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, required this.id});
  final String id;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  Map<String, dynamic>? _d;
  String? _newest;
  String? _error;
  String? _done;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await api.get('/admin/people/${widget.id}');
      if (!mounted) return;
      setState(() {
        _d = Map<String, dynamic>.from(d);
        _error = null;
      });
      newestVersion().then((v) {
        if (mounted && v != null) setState(() => _newest = v);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  bool get _isStudent => _d?['account']?['role'] == 'student';

  Future<void> _signOut(String name, Map<String, dynamic> body, String phone) async {
    final yes = await confirmCard(
      context,
      title: 'Sign out this phone?',
      body: '$name is signed out on $phone and needs the username and ${_isStudent ? 'PIN' : 'password'} to log back in there.',
      confirm: 'Sign out',
      destructive: true,
    );
    if (!yes) return;
    try {
      final r = await api.post('/admin/people/${widget.id}/sign-out', body);
      setState(() => _done = f.asInt(r['signed_out']) > 0 ? 'Signed out on $phone.' : 'That phone was already signed out.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  Future<void> _unlock(String name) async {
    try {
      await api.post('/admin/people/${widget.id}/unlock');
      setState(() => _done = '$name can log in again.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return PushedPanel(title: 'Account', children: [
        if (_error != null) ErrorState(message: _error!, onRetry: _load) else const LoadingState(),
      ]);
    }
    final a = Map<String, dynamic>.from(d['account']);
    final stats = Map<String, dynamic>.from(d['stats'] ?? {});
    final phones = (d['phones'] as List).cast<Map<String, dynamic>>();
    final old = (d['old_sessions'] as List).cast<Map<String, dynamic>>();
    final logins = (d['logins'] as List).cast<Map<String, dynamic>>();
    final tests = (d['tests'] as List).cast<Map<String, dynamic>>();
    final name = '${a['display_name']}';
    final seen = f.parseTime(a['last_seen_at']);
    final online = seen != null && DateTime.now().difference(seen).inMinutes < 5;
    final subjects = (a['subjects'] as List? ?? const []).join(', ');

    return PushedPanel(
      kicker: a['role'] == 'teacher' ? 'Teacher' : 'Student · Class ${a['class_level']}',
      title: name,
      children: [
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          TagChip('${a['username']}'),
          if (subjects.isNotEmpty) TagChip(subjects),
          if (a['active'] != true)
            const TagChip('Turned off', tone: Tone.danger)
          else if (a['locked'] == true)
            const TagChip('Locked', tone: Tone.danger)
          else
            TagChip(online ? 'Online now' : 'Seen ${f.ago(seen)}', tone: online ? Tone.success : Tone.neutral),
        ]),
        if (_done != null) ...[const SizedBox(height: 14), InlineNotice(_done!, tone: Tone.success, icon: Ph.checkCircle)],
        if (a['locked'] == true) ...[
          const SizedBox(height: 14),
          InlineNotice('Locked after 5 wrong tries, until ${f.clock(f.parseTime(a['locked_until']))}. It unlocks by itself.', tone: Tone.danger, icon: Ph.lockKey),
          const SizedBox(height: 10),
          SecondaryButton('Unlock now', icon: Ph.lockKeyOpen, onTap: () => _unlock(name)),
        ],
        if (a['role'] == 'student') ...[
          const SizedBox(height: 18),
          StatGrid(
            label: 'Tests written',
            value: '${stats['tests_written'] ?? 0}',
            note: stats['last_submitted_at'] == null ? 'None yet' : 'Last one ${f.ago(f.parseTime(stats['last_submitted_at']))}',
            small: [
              StatSmall('Average', stats['average_pct'] == null ? '-' : '${stats['average_pct']}%'),
              StatSmall('Best', stats['best_pct'] == null ? '-' : '${stats['best_pct']}%'),
            ],
          ),
        ],
        SectionRule('Phones', count: phones.length + old.length, padding: _rule),
        if (phones.isEmpty && old.isEmpty) Text('Not signed in on any phone.', style: bodyStyle.copyWith(color: muted)),
        for (final (i, p) in phones.indexed) ...[if (i > 0) const SizedBox(height: gapRow), _phone(name, p)],
        for (final s in old) ...[const SizedBox(height: gapRow), _oldSession(name, s)],
        SectionRule('Logins', count: logins.isEmpty ? null : logins.length, padding: _rule),
        if (logins.isEmpty)
          Text('No logins recorded yet. The history starts with this version of the server.', style: bodyStyle.copyWith(color: muted))
        else
          for (final (i, e) in logins.take(12).indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              leading: Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: e['outcome'] == 'ok' || e['outcome'] == 'signup' ? successSoft : dangerSoft, shape: BoxShape.circle),
                child: Icon(e['outcome'] == 'ok' || e['outcome'] == 'signup' ? Ph.check : Ph.x, size: 16, color: e['outcome'] == 'ok' || e['outcome'] == 'signup' ? success : danger),
              ),
              title: switch (e['outcome']) {
                'ok' => _isStudent ? 'PIN right' : 'Password right',
                'signup' => 'Signed up',
                'wrong_secret' => _isStudent ? 'Wrong PIN' : 'Wrong password',
                'lockout' => 'Locked after 5 wrong tries',
                'locked' => 'Tried while locked',
                'inactive' => 'Tried while turned off',
                _ => '${e['outcome']}',
              },
              meta: [if (e['model'] != null) '${e['model']}', if (e['app_version'] != null) 'app ${e['app_version']}'].join(' · ').ifEmpty('Phone not known (app 1.2.0 or older)'),
              trailing: Fig(f.ago(f.parseTime(e['at'])), style: labelStyle),
            ),
          ],
        if (tests.isNotEmpty) ...[
          const SectionRule('Recent tests', padding: _rule),
          for (final (i, t) in tests.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              title: '${t['title']}${f.asInt(t['attempt_no']) > 1 ? ' (retake)' : ''}',
              meta: '${f.ago(f.parseTime(t['submitted_at']))}${t['auto_submitted'] == true ? ' · time ran out' : ''}',
              trailing: Text('${_mark(t['score'])}/${_mark(t['max_score'])}', style: numStyle(size: 15)),
            ),
          ],
        ],
      ],
    );
  }

  String _mark(Object? v) {
    final x = f.asDouble(v);
    return x == x.roundToDouble() ? '${x.round()}' : x.toStringAsFixed(1);
  }

  Widget _fact(String label, String value, {Color? color}) => Padding(
        padding: const EdgeInsets.only(top: 9),
        child: Row(children: [
          Text(label, style: bodyStyle.copyWith(color: muted)),
          const SizedBox(width: 16),
          Expanded(child: Fig(value, style: rowTitleStyle.copyWith(color: color), textAlign: TextAlign.right)),
        ]),
      );

  Widget _phone(String name, Map<String, dynamic> p) {
    final last = f.parseTime(p['last_seen_at']);
    final online = p['signed_in'] == true && last != null && DateTime.now().difference(last).inMinutes < 5;
    final model = '${p['model'] ?? 'Unknown phone'}';
    final others = f.asInt(p['other_accounts']);
    return Surface(
      shadow: e1,
      padding: const EdgeInsets.fromLTRB(17, 15, 17, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: online ? success : (p['signed_in'] == true ? muted : faint), shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(child: Fig(model, style: rowTitleStyle, maxLines: 1)),
          if (p['app_version'] != null) versionTag('${p['app_version']}', _newest),
        ]),
        _fact('Android', '${p['os_version'] ?? '-'}'.replaceFirst('Android ', '')),
        _fact('First used', f.when(f.parseTime(p['first_seen_at']))),
        _fact('Last used', online ? 'now' : f.when(last)),
        if (others > 0) _fact('Also used by', f.plural(others, 'other account'), color: warning),
        const SizedBox(height: 4),
        if (p['signed_in'] == true)
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction('Sign out this phone', color: danger, onTap: () => _signOut(name, {'install_id': p['install_id']}, model)),
          )
        else
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('Signed out', style: labelStyle)),
      ]),
    );
  }

  Widget _oldSession(String name, Map<String, dynamic> s) => Surface(
        shadow: e1,
        padding: const EdgeInsets.fromLTRB(17, 15, 17, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: muted, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Text('A phone on app 1.2.0 or older', style: rowTitleStyle)),
            const TagChip('Older app'),
          ]),
          _fact('Signed in', f.when(f.parseTime(s['created_at']))),
          _fact('Last used', f.when(f.parseTime(s['last_used_at']))),
          Padding(padding: const EdgeInsets.only(top: 9), child: Text('Its model shows once it updates.', style: labelStyle)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction('Sign out this phone', color: danger, onTap: () => _signOut(name, {'session': s['session']}, 'that phone')),
          ),
        ]),
      );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
