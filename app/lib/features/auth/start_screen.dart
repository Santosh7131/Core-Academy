import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

/// Shown for the moment it takes to restore the session. Static: no spinner.
class StartScreen extends StatelessWidget {
  const StartScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 36, gutter, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Kicker('Maths tests'),
              const SizedBox(height: 8),
              Text(session.tuitionName, style: displayStyle),
            ]),
          ),
        ),
      );
}
