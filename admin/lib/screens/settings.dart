import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/session.dart';
import '../theme.dart';
import '../ui/common.dart';
import '../ui/kit.dart';
import 'update_card.dart';

const _rule = EdgeInsets.fromLTRB(0, 26, 0, 11);

/// Which database to read, the theme, this app's version and updates, and logging out.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  /// The Neon branch the API runs on ("br-cold-shape-azcvozbw"), or host and port for a PC.
  String _server() {
    final u = Uri.parse(api.base);
    return u.host.endsWith('neon.tech') ? u.host.split('.').first.replaceFirst(RegExp(r'-api$'), '') : '${u.host}:${u.port}';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) => PushedPanel(
          kicker: 'Admin',
          title: 'Settings',
          children: [
            const SectionRule('Database', padding: _rule),
            Wrap(spacing: 8, children: [
              for (final (env, label) in [(Env.live, 'Live'), (Env.dev, 'Dev')])
                SegChip(label, selected: api.env == env, onTap: () async {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                  await session.switchTo(env);
                }),
            ]),
            const SizedBox(height: 10),
            Fig('Live is what students use; dev is the test copy. Each has its own developer login.', style: labelStyle),
            const SectionRule('Signed in', padding: _rule),
            FactList([('Username', '${session.user?['username'] ?? '-'}'), ('Server', _server())]),
            const SectionRule('Theme', padding: _rule),
            Wrap(spacing: 8, children: [
              for (final (t, label) in [(ThemeChoice.system, 'Same as phone'), (ThemeChoice.light, 'Light'), (ThemeChoice.dark, 'Dark')])
                SegChip(label, selected: session.theme == t, onTap: () => session.setTheme(t)),
            ]),
            const SectionRule('App', padding: _rule),
            const AppVersionPanel(),
            const SizedBox(height: 34),
            SecondaryButton('Log out', icon: Ph.signOut, tint: danger, onTap: () async {
              final ok = await confirmCard(context,
                  title: 'Log out?', body: 'You will need the developer password to log back in.', confirm: 'Log out', destructive: true);
              if (ok) {
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                await session.logout();
              }
            }),
          ],
        ),
      );
}
