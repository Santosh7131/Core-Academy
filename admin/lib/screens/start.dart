import 'package:flutter/material.dart';

import '../theme.dart';
import '../ui/kit.dart';

/// Shown for the moment it takes to restore the login, as in the main app. Static: no spinner.
class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 36, gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Kicker('Core Academy'),
              const SizedBox(height: 8),
              Text('Admin', style: displayStyle),
            ]),
          ),
        ),
      );
}
