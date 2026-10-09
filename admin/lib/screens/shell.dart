import 'package:flutter/material.dart';

import '../core/updater.dart';
import '../theme.dart';
import '../ui/kit.dart';
import 'clients.dart';
import 'log.dart';
import 'overview.dart';
import 'people.dart';
import 'server.dart';

/// Five tabs under the main app's floating navigation surface (solid, no blur).
class Shell extends StatefulWidget {
  const Shell({super.key});

  /// The tabs, by position, for [go].
  static const overview = 0, clients = 1, people = 2, server = 3, log = 4;

  /// Lets a screen switch tabs (an Overview row opens Clients, Server or Log).
  static void go(BuildContext context, int tab) => context.findAncestorStateOfType<_ShellState>()?._select(tab);

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  final _visited = <int>{0};

  static const _items = [
    (Ph.gauge, 'Overview'),
    (Ph.buildings, 'Clients'),
    (Ph.users, 'People'),
    (Ph.hardDrives, 'Server'),
    (Ph.listBullets, 'Log'),
  ];

  @override
  void initState() {
    super.initState();
    updater.check();
  }

  void _select(int i) => setState(() {
        _tab = i;
        _visited.add(i);
      });

  @override
  Widget build(BuildContext context) {
    // A tab is built the first time it is opened, then kept.
    Widget page(int i, Widget Function() make) => _visited.contains(i) ? make() : const SizedBox();
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: SafeArea(
            bottom: false,
            child: IndexedStack(index: _tab, children: [
              page(0, () => const OverviewScreen()),
              page(1, () => const ClientsScreen()),
              page(2, () => const PeopleScreen()),
              page(3, () => const ServerScreen()),
              page(4, () => const LogScreen()),
            ]),
          ),
        ),
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
                    onTap: () => _select(i),
                    child: SizedBox(
                      height: 64,
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, size: 22, color: i == _tab ? ink : muted),
                        const SizedBox(height: 3),
                        Text(label, style: tagStyle.copyWith(fontWeight: FontWeight.w600, color: i == _tab ? ink : muted)),
                      ]),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}
