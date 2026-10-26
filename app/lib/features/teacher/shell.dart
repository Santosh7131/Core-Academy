import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../ui/floating_tabs.dart';
import '../../ui/kit.dart';

/// Teacher tabs with a floating navigation surface (solid, no blur).
/// Home, Courses and Groups: everything else (students, tests, uploads) is inside a group or a course.
class TeacherShell extends StatelessWidget {
  const TeacherShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _items = [
    (Ph.house, 'Home'),
    (Ph.graduationCap, 'Courses'),
    (Ph.users, 'Groups'),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(children: [
          Positioned.fill(child: shell),
          FloatingTabs.positioned(
            context,
            child: FloatingTabs(
              items: _items,
              index: shell.currentIndex,
              onTap: (i) => shell.goBranch(i, initialLocation: i == shell.currentIndex),
            ),
          ),
        ]),
      );
}
