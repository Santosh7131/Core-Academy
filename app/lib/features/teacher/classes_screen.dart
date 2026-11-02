import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';
import 'course_screens.dart' show coursePath, newCourse;
import 'group_screens.dart' show groupPath, startNewGroup;

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// Asks what kind of class to add, then asks for its details and opens it. The screen that asked loads its list again when this is over.
Future<void> addClass(BuildContext context) async {
  final kind = await showCentredCard<String>(
    context,
    title: 'Add a class',
    subtitle: 'What kind?',
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RowTile(
        leading: Icon(Ph.users, size: 22, color: ink),
        title: 'A group',
        meta: 'A class and a subject, like 10th Maths',
        chevron: true,
        onTap: () => Navigator.of(ctx).pop('group'),
      ),
      const SizedBox(height: 10),
      RowTile(
        leading: Icon(Ph.graduationCap, size: 22, color: ink),
        title: 'A course',
        meta: 'People you teach apart from your groups',
        chevron: true,
        onTap: () => Navigator.of(ctx).pop('course'),
      ),
    ]),
  );
  if (kind == null || !context.mounted) return;
  if (kind == 'group') {
    await startNewGroup(context);
    return;
  }
  final c = await newCourse(context);
  if (c == null || !context.mounted) return;
  // A new course opens at once, so the people can be added.
  await context.push(coursePath(c));
}

/// The Classes tab: every group and every course of the tuition in one list, with one button to add either.
class ClassesScreen extends StatefulWidget {
  const ClassesScreen({super.key});

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> with WidgetsBindingObserver, AutoRefresh<ClassesScreen> {
  List<Map<String, dynamic>>? _groups;
  List<Map<String, dynamic>> _courses = const [];
  String? _error;

  @override
  Set<Area> get refreshAreas => {Area.tests, Area.students, Area.courses};

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    markLoaded();
    try {
      final d = await api.get('/teacher/home');
      if (mounted) {
        setState(() {
          _groups = (d['groups'] as List).cast<Map<String, dynamic>>();
          _courses = ((d['courses'] as List?) ?? const []).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _add() async {
    await addClass(context);
    if (mounted) _load();
  }

  Future<void> _open(String path) async {
    await context.push(path);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final total = groups == null ? 0 : groups.length + _courses.length;
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          TabHeader(kicker: total == 0 ? 'Your classes' : f.count(total, 'class', 'classes'), title: 'Classes'),
          if (groups == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (groups == null)
            const LoadingState(inset: true, rows: 3)
          else if (total == 0)
            EmptyState(
              icon: Ph.users,
              title: 'No classes yet',
              body: 'A class is a group of students, like 10th Maths. Add one, then add your students to it.',
              action: PrimaryButton('Add a class', leadingIcon: Ph.plus, onTap: _add),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
              child: PrimaryButton('Add a class', leadingIcon: Ph.plus, onTap: _add),
            ),
            ...staggered(_sections(groups), scope: this, prefix: 'classes', stepMs: 50),
          ],
          navClearance,
        ]),
      ),
    );
  }

  /// Every group, then every course, as one list: each row says by its tag whether it is a group or a course, so no
  /// heading is needed. A row carries every row's spacing, so each comes in after the one before it.
  List<Widget> _sections(List<Map<String, dynamic>> groups) {
    Widget tile({required String title, required String meta, required String kind, required int live, required VoidCallback onTap}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          child: TaggedRow(
            title: title,
            meta: meta,
            tag: TagChip(kind, outlined: true),
            note: live > 0 ? '$live open' : null,
            noteColor: success,
            noteBold: true,
            chevron: true,
            onTap: onTap,
          ),
        );

    String coming(Map<String, dynamic> x) => (x['posted'] as List).isEmpty ? '' : ' · ${(x['posted'] as List).length} coming up';
    final tiles = <Widget>[
      for (final g in groups)
        tile(
          title: groupName(g['class_level'] as int, '${g['subject']}'),
          meta: '${f.count(_n(g['students']), 'student')}${coming(g)}',
          kind: 'Group',
          live: (g['live'] as List).length,
          onTap: () => _open(groupPath(g)),
        ),
      for (final c in _courses)
        tile(
          title: '${c['name']}',
          meta: '${f.count(_n(c['people']), 'person', 'people')}${coming(c)}',
          kind: 'Course',
          live: (c['live'] as List).length,
          onTap: () => _open(coursePath(c)),
        ),
    ];
    return [
      const SizedBox(height: 18),
      for (final (i, w) in tiles.indexed) ...[if (i > 0) const SizedBox(height: gapRow), w],
    ];
  }
}
