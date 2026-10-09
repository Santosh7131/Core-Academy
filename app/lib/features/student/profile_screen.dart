import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';
import '../../core/levels.dart';

/// Profile for students and the teacher: who is signed in, theme, log out.
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final u = session.user ?? {};
          final teacher = session.isTeacher;
          Widget fact(String label, String value) => Padding(
                padding: const EdgeInsets.fromLTRB(17, 14, 17, 14),
                child: Row(children: [
                  Expanded(child: Text(label, style: bodyStyle.copyWith(color: muted))),
                  Fig(value, style: rowTitleStyle),
                ]),
              );
          Widget line() => Container(height: 1, margin: const EdgeInsets.only(left: 17), color: hairline);
          return PushedPanel(
            kicker: teacher ? 'Tutor' : className(session.classLevel),
            title: '${u['display_name'] ?? ''}',
            children: [
              const SizedBox(height: 22),
              Surface(
                shadow: e1,
                child: Column(children: [
                  fact('Username', '${u['username'] ?? ''}'),
                  line(),
                  fact('Tuition', session.tuitionName),
                ]),
              ),
              if (!teacher) ...[
                SectionRule('Tuitions', count: session.tuitions.length, padding: const EdgeInsets.fromLTRB(0, 26, 0, 12)),
                for (final (i, t) in session.tuitions.indexed) ...[
                  if (i > 0) const SizedBox(height: gapRow),
                  t['status'] == 'pending'
                      ? RowTile(title: '${t['name']}', meta: 'Waiting for the tutor to let you in', trailing: const TagChip('Waiting', tone: Tone.warning))
                      : RowTile(
                          title: '${t['name']}',
                          meta: '${className(t['class_level'], tuition: t)}${t['id'] == session.tuitionId ? ' · showing now' : ''}',
                          chevron: t['id'] != session.tuitionId,
                          onTap: t['id'] == session.tuitionId
                              ? null
                              : () {
                                  session.switchTuition('${t['id']}');
                                  context.go('/s');
                                },
                        ),
                ],
                const SizedBox(height: gapRow),
                SecondaryButton('Join another tuition', icon: Ph.plus, onTap: () => context.push('/s/join')),
              ],
              const SectionRule('Theme', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
              SegmentedToggle(
                labels: const ['Phone', 'Light', 'Dark'],
                index: ThemeChoice.values.indexOf(session.theme),
                onChanged: (i) => session.setTheme(ThemeChoice.values[i]),
              ),
              const SectionRule('App', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
              const AppVersionPanel(),
              const SizedBox(height: 34),
              SecondaryButton(
                'Log out',
                icon: Ph.signOut,
                tint: danger,
                onTap: () async {
                  final ok = await confirmCard(
                    context,
                    title: 'Log out?',
                    body: teacher
                        ? 'You will need your username and password to log back in.'
                        : 'You will need your username and PIN to log back in.',
                    confirm: 'Log out',
                    destructive: true,
                  );
                  if (ok) session.logout();
                },
              ),
            ],
          );
        },
      );
}
