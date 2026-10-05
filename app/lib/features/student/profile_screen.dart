import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/update_card.dart';

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
            kicker: teacher ? 'Teacher' : 'Class ${u['class_level'] ?? ''}${u['school'] == null ? '' : ' · ${u['school']}'}',
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
              const SectionRule('Theme', padding: EdgeInsets.fromLTRB(0, 26, 0, 12)),
              Wrap(spacing: 8, children: [
                for (final (t, label) in [(ThemeChoice.system, 'Same as phone'), (ThemeChoice.light, 'Light'), (ThemeChoice.dark, 'Dark')])
                  SegChip(label, selected: session.theme == t, onTap: () => session.setTheme(t)),
              ]),
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
