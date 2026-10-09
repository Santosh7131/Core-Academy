import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../theme.dart';
import '../../ui/kit.dart';

/// Teacher tabs with a floating navigation surface (solid, no blur).
/// Home and Groups: everything else (students, tests, uploads) is inside a group.
class TeacherShell extends StatelessWidget {
  const TeacherShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _items = [
    (Ph.house, 'Home'),
    (Ph.users, 'Groups'),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Stack(children: [
          Positioned.fill(child: shell),
          Positioned(
            left: 16,
            right: 16,
            bottom: 12 + MediaQuery.paddingOf(context).bottom,
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(rPill),
                border: isDark ? Border.all(color: hairline) : null,
                boxShadow: e4,
              ),
              child: Row(children: [
                for (final (i, (icon, label)) in _items.indexed)
                  Expanded(
                    child: Pressable(
                      label: label,
                      onTap: () => shell.goBranch(i, initialLocation: i == shell.currentIndex),
                      child: _NavItem(icon: icon, label: label, selected: i == shell.currentIndex),
                    ),
                  ),
              ]),
            ),
          ),
        ]),
      );
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.label, required this.selected});
  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? ink : muted;
    return SizedBox(
      height: 64,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 24, color: fg),
        const SizedBox(height: 3),
        Text(label, style: tagStyle.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}
