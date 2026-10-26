import 'package:flutter/material.dart';

import '../theme.dart';
import 'kit.dart';

/// The floating navigation surface (solid, no blur): a pill of icon-and-label tabs that sits above the screen's
/// content. The tutor's Home, Courses and Groups use it, and so does a student's Tests and Courses.
class FloatingTabs extends StatelessWidget {
  const FloatingTabs({super.key, required this.items, required this.index, required this.onTap});

  /// Each tab's icon and label.
  final List<(IconData, String)> items;
  final int index;
  final ValueChanged<int> onTap;

  /// The pill's height; the content behind it needs this and a margin of clearance.
  static const height = 64.0;

  /// Where the pill sits: 16 in from each side and 12 above the bottom edge of the safe area.
  static Widget positioned(BuildContext context, {required Widget child}) =>
      Positioned(left: 16, right: 16, bottom: 12 + MediaQuery.paddingOf(context).bottom, child: child);

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        decoration: BoxDecoration(
          color: card,
          borderRadius: BorderRadius.circular(rPill),
          border: isDark ? Border.all(color: hairline) : null,
          boxShadow: e4,
        ),
        child: Row(children: [
          for (final (i, (icon, label)) in items.indexed)
            Expanded(
              child: Pressable(
                label: label,
                onTap: () => onTap(i),
                child: _TabItem(icon: icon, label: label, selected: i == index),
              ),
            ),
        ]),
      );
}

class _TabItem extends StatelessWidget {
  const _TabItem({required this.icon, required this.label, required this.selected});
  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? ink : muted;
    return SizedBox(
      height: FloatingTabs.height,
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 24, color: fg),
        const SizedBox(height: 3),
        Text(label, style: tagStyle.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}
