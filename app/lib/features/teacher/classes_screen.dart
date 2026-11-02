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

/// Asks for a course's name, makes it and opens it at once, so its people can be added.
Future<void> _addCourse(BuildContext context) async {
  final c = await newCourse(context);
  if (c == null || !context.mounted) return;
  await context.push(coursePath(c));
}

/// Asks whether to add a group or a course, then asks for its details and opens it. Home uses it when there is nothing yet; the
/// Groups & courses tab has one button for each kind. The screen that asked loads its list again when this is over.
Future<void> addGroupOrCourse(BuildContext context) async {
  final kind = await showCentredCard<String>(
    context,
    title: 'Add a group or course',
    subtitle: 'Which one?',
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
  await _addCourse(context);
}

/// Which kind of class the switch shows.
enum _Kind { groups, courses }

/// The Groups & courses tab: a switch between the tutor's groups and the tutor's courses, so the two are never mixed in one
/// list, and one button to add the kind that is showing.
class ClassesScreen extends StatefulWidget {
  const ClassesScreen({super.key});

  @override
  State<ClassesScreen> createState() => _ClassesScreenState();
}

class _ClassesScreenState extends State<ClassesScreen> with WidgetsBindingObserver, AutoRefresh<ClassesScreen> {
  List<Map<String, dynamic>>? _groups;
  List<Map<String, dynamic>> _courses = const [];
  String? _error;

  /// The kind the switch shows: decided when the lists first arrive (groups, unless the tutor has only courses), and the
  /// tutor's own choice after that.
  _Kind? _kind;

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
          _kind ??= _groups!.isEmpty && _courses.isNotEmpty ? _Kind.courses : _Kind.groups;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _addGroup() async {
    await startNewGroup(context);
    if (mounted) _load();
  }

  Future<void> _addNewCourse() async {
    await _addCourse(context);
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
    final kind = _kind ?? _Kind.groups;
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          TabHeader(kicker: '$total in all', title: 'Groups & courses', titleLines: 3),
          if (groups == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (groups == null)
            const LoadingState(inset: true, rows: 3)
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 18, gutter, 0),
              child: SegmentedToggle(
                labels: const ['Groups', 'Courses'],
                counts: [groups.length, _courses.length],
                index: kind.index,
                onChanged: (i) => setState(() => _kind = _Kind.values[i]),
              ),
            ),
            ...switch (kind) {
              _Kind.groups => _groupList(groups),
              _Kind.courses => _courseList(),
            },
          ],
          navClearance,
        ]),
      ),
    );
  }

  /// One row: the name, how many people and what is coming up, and "1 open" at the right when a test is open now.
  Widget _row({required String title, required String meta, required int live, required VoidCallback onTap}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: gutter),
        // "1 open" sits beside the name, or under the details when large text leaves the name too little room.
        child: TaggedRow(
          title: title,
          meta: meta,
          note: live > 0 ? '$live open' : null,
          noteColor: success,
          noteBold: true,
          chevron: true,
          onTap: onTap,
        ),
      );

  String _coming(Map<String, dynamic> x) => (x['posted'] as List).isEmpty ? '' : ' · ${(x['posted'] as List).length} coming up';

  /// The add button, then the rows. A row carries every row's spacing, so each comes in after the one before it.
  List<Widget> _list({required String add, required VoidCallback onAdd, required List<Widget> rows, required String prefix}) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(gutter, 14, gutter, 0),
          child: PrimaryButton(add, leadingIcon: Ph.plus, onTap: onAdd),
        ),
        ...staggered([
          const SizedBox(height: 14),
          for (final (i, w) in rows.indexed) ...[if (i > 0) const SizedBox(height: gapRow), w],
        ], scope: this, prefix: prefix, stepMs: 50),
      ];

  List<Widget> _groupList(List<Map<String, dynamic>> groups) {
    if (groups.isEmpty) {
      return [
        EmptyState(
          icon: Ph.users,
          title: 'No groups yet',
          body: 'A group is a class and a subject, like 10th Maths. Add one, then add your students to it.',
          action: PrimaryButton('Add a group', leadingIcon: Ph.plus, onTap: _addGroup),
        ),
      ];
    }
    return _list(
      add: 'Add a group',
      onAdd: _addGroup,
      prefix: 'groups',
      rows: [
        for (final g in groups)
          _row(
            title: groupName(g['class_level'] as int, '${g['subject']}'),
            meta: '${f.count(_n(g['students']), 'student')}${_coming(g)}',
            live: (g['live'] as List).length,
            onTap: () => _open(groupPath(g)),
          ),
      ],
    );
  }

  List<Widget> _courseList() {
    if (_courses.isEmpty) {
      return [
        EmptyState(
          icon: Ph.graduationCap,
          title: 'No courses yet',
          body: 'A course is for people you teach apart from your groups, like a spoken English batch. Add one, then add its people.',
          action: PrimaryButton('Add a course', leadingIcon: Ph.plus, onTap: _addNewCourse),
        ),
      ];
    }
    return _list(
      add: 'Add a course',
      onAdd: _addNewCourse,
      prefix: 'courses',
      rows: [
        for (final c in _courses)
          _row(
            title: '${c['name']}',
            meta: '${f.count(_n(c['people']), 'person', 'people')}${_coming(c)}',
            live: (c['live'] as List).length,
            onTap: () => _open(coursePath(c)),
          ),
      ],
    );
  }
}
