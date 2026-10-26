import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../ui/kit.dart';
import 'start_card.dart';
import 'test_sections.dart';

/// One course a student is in: the test to write now, its results and what is coming up, kept apart from the
/// class's tests. Its marks and results show only here.
class StudentCourseScreen extends StatefulWidget {
  const StudentCourseScreen({super.key, required this.id, required this.name});
  final String id;

  /// The course's name, shown until the page has loaded.
  final String name;

  @override
  State<StudentCourseScreen> createState() => _StudentCourseScreenState();
}

class _StudentCourseScreenState extends State<StudentCourseScreen> with WidgetsBindingObserver, AutoRefresh<StudentCourseScreen> {
  Map<String, dynamic>? _d;
  String? _error;
  bool _loading = false;

  String get _name => _d == null ? widget.name : '${_d!['course']['name']}';

  @override
  Set<Area> get refreshAreas => {Area.student};

  // A new test from the teacher shows up within a minute while this is on screen.
  @override
  Duration? get pollEvery => const Duration(seconds: 60);

  @override
  Future<void> refreshQuietly() => _load();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    markLoaded();
    setState(() => _loading = true);
    try {
      final d = await api.get('/student/courses/${widget.id}');
      _d = Map<String, dynamic>.from(d);
      _error = null;
    } on ApiException catch (e) {
      _error = e.message;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(String path) async {
    await context.push(path);
    if (mounted) _load();
  }

  Future<void> _start(Map<String, dynamic> t) async {
    if (t['state'] != 'in_progress' && !await confirmStart(context, t)) return;
    if (mounted) _open('/s/write/${t['id']}');
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return PushedPanel(
      onRefresh: _load,
      kicker: 'Course',
      title: _name,
      children: [
        if (d == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (d == null)
          const LoadingState(rows: 3)
        else ...[
          if (_error != null) ...[const SizedBox(height: 14), InlineNotice(_error!, icon: Ph.warning)],
          ...staggered(_body((d['tests'] as List).cast<Map<String, dynamic>>()), scope: this, prefix: 'course', stepMs: 70),
        ],
      ],
    );
  }

  /// The sections have no side space of their own here: the panel already keeps its gutter.
  List<Widget> _body(List<Map<String, dynamic>> tests) => [
        const SizedBox(height: 18),
        InlineNotice('This course is separate from your class tests. Its tests and results show only here.', tone: Tone.neutral, icon: Ph.graduationCap),
        ...testSections(
          context,
          tests,
          onStart: _start,
          onOpen: _open,
          side: 0,
          emptyTitle: 'No tests yet',
          emptyBody: 'When your tutor posts a test in this course, it shows up here.',
        ),
      ];
}
