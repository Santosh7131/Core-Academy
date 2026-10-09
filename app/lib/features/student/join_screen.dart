import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../core/levels.dart';

/// A student's tuitions, and asking to join another with its code. A student who is in none yet
/// (the router sends them here) can only do this; a tutor lets them in, and then they land on Home.
class JoinScreen extends StatefulWidget {
  const JoinScreen({super.key});

  @override
  State<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends State<JoinScreen> with WidgetsBindingObserver, AutoRefresh<JoinScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _sent;

  /// True when the student is in no tuition yet and is waiting to be let into the first.
  late final bool _waiting = session.needsTuition;

  @override
  Set<Area> get refreshAreas => {Area.student};

  // While waiting to be let in, check now and then so the first test appears by itself.
  @override
  Duration? get pollEvery => _waiting ? const Duration(seconds: 20) : null;

  @override
  Future<void> refreshQuietly() => session.refreshTuitions();

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _code.dispose();
    super.dispose();
  }

  void _onSession() {
    if (_waiting && !session.needsTuition && mounted) context.go('/s');
  }

  Future<void> _join() async {
    FocusScope.of(context).unfocus();
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Type the code your tutor gave you.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _sent = null;
    });
    try {
      final r = await session.joinTuition(_code.text);
      if (mounted) {
        setState(() {
          _sent = 'Asked ${r['tuition']['name']}. You will see their tests here once they let you in.';
          _code.clear();
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(Map<String, dynamic> t) {
    session.switchTuition('${t['id']}');
    context.go('/s');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: PullToRefresh(
            onRefresh: session.refreshTuitions,
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 28),
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  Row(children: [
                    if (Navigator.of(context).canPop()) CircleBtn(icon: Ph.arrowLeft, label: 'Back', onTap: () => Navigator.of(context).maybePop()),
                  ]),
                  const SizedBox(height: 22),
                  Kicker(_waiting ? 'Welcome' : 'Your tuitions'),
                  const SizedBox(height: 6),
                  Text('Join a tuition', style: displayStyle),
                  const SizedBox(height: 10),
                  Fig(
                    _waiting
                        ? 'Ask your tutor for their join code and enter it below.'
                        : 'Enter the code from another tutor to join their tuition as well.',
                    style: bodyStyle.copyWith(color: muted),
                  ),
                  if (session.tuitions.isNotEmpty) ...[
                    SectionRule('Your tuitions', count: session.tuitions.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
                    for (final (i, t) in session.tuitions.indexed) ...[
                      if (i > 0) const SizedBox(height: gapRow),
                      t['status'] == 'pending'
                          ? RowTile(title: '${t['name']}', meta: 'Waiting for the tutor to let you in', trailing: const TagChip('Waiting', tone: Tone.warning))
                          : RowTile(
                              title: '${t['name']}',
                              meta: '${className(t['class_level'], tuition: t)}${t['id'] == session.tuitionId ? ' · showing now' : ''}',
                              chevron: true,
                              onTap: () => _open(t),
                            ),
                    ],
                  ],
                  SectionRule('Join with a code', padding: const EdgeInsets.fromLTRB(0, 26, 0, 11)),
                  GroupedInputs(children: [
                    BareField(
                      controller: _code,
                      placeholder: 'Join code, like KR7-4MQ',
                      capitalization: TextCapitalization.characters,
                      keyboard: TextInputType.visiblePassword,
                      action: TextInputAction.done,
                      onSubmitted: (_) => _join(),
                    ),
                  ]),
                  if (_error != null) ...[const SizedBox(height: 14), InlineNotice(_error!, icon: Ph.warning)],
                  if (_sent != null) ...[const SizedBox(height: 14), InlineNotice(_sent!, tone: Tone.success, icon: Ph.checkCircle)],
                  const SizedBox(height: 18),
                  PrimaryButton(_busy ? 'Sending' : 'Ask to join', onTap: _busy ? null : _join),
                  if (_waiting) ...[
                    const SizedBox(height: 22),
                    Center(
                      child: TextAction('Log out', onTap: () async {
                        final ok = await confirmCard(context, title: 'Log out?', body: 'You will need your username and PIN to log back in.', confirm: 'Log out', destructive: true);
                        if (ok) session.logout();
                      }),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}
