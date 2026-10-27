import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/tokens.dart';

String _enc(String s) => Uri.encodeComponent(s);

/// Who a new test is for: a group (a class and a subject) or a course. Making a test starts the same way for both, so every
/// "Make a test" button, on Home and on a group's or a course's page, goes through here.
class TestTarget {
  const TestTarget._({this.classLevel, this.subjectId, this.courseId, required this.name, required this.plainName, required this.size});

  /// A group: a class and a subject. [subjectName] is the subject alone ("Maths"), [size] the number of students.
  factory TestTarget.group({required int classLevel, required String subjectId, required String subjectName, int size = 0}) =>
      TestTarget._(classLevel: classLevel, subjectId: subjectId, name: groupName(classLevel, subjectName), plainName: subjectName, size: size);

  /// A course, with the number of people in it.
  factory TestTarget.course({required String id, required String name, int size = 0}) =>
      TestTarget._(courseId: id, name: name, plainName: name, size: size);

  /// A group as the server's Home lists it: {class_level, subject_id, subject, students}.
  factory TestTarget.fromGroup(Map<String, dynamic> g) => TestTarget.group(
        classLevel: (g['class_level'] as num).toInt(),
        subjectId: '${g['subject_id']}',
        subjectName: '${g['subject']}',
        size: _int(g['students']),
      );

  /// A course as the server's Home lists it: {id, name, people}.
  factory TestTarget.fromCourse(Map<String, dynamic> c) => TestTarget.course(id: '${c['id']}', name: '${c['name']}', size: _int(c['people']));

  final int? classLevel;
  final String? subjectId;
  final String? courseId;

  /// What the tutor calls it: "10th Maths", or the course's name.
  final String name;

  /// The name that rides along in the address of the next page: the subject for a group, the course's name for a course.
  final String plainName;
  final int size;

  bool get isCourse => courseId != null;

  /// "12 students", "14 people".
  String get sizeLabel => isCourse ? f.count(size, 'person', 'people') : f.count(size, 'student');

  String get uploadPath => isCourse
      ? '/t/papers/new?course=$courseId&name=${_enc(plainName)}'
      : '/t/papers/new?class=$classLevel&subject=$subjectId&name=${_enc(plainName)}';

  String get chatPath => isCourse ? '/t/courses/$courseId/chat?name=${_enc(plainName)}' : '/t/groups/$classLevel/$subjectId/chat?name=${_enc(plainName)}';

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
}

/// Asks how the test is made (from a paper, or described to AI) and opens that. Returns true when something was opened and the
/// tutor has come back from it, so the screen can load again.
Future<bool> makeTestFor(BuildContext context, TestTarget target) async {
  final choice = await showCentredCard<String>(
    context,
    title: 'Make a test',
    subtitle: 'For ${target.name}',
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      RowTile(
        leading: Icon(Ph.fileArrowUp, size: 22, color: ink),
        title: 'Upload a PDF or photos',
        meta: 'AI reads the questions',
        chevron: true,
        onTap: () => Navigator.of(ctx).pop('upload'),
      ),
      const SizedBox(height: 10),
      RowTile(
        leading: Icon(Ph.scan, size: 22, color: aiAccentInk),
        title: 'Describe it to AI',
        meta: 'AI writes the questions',
        chevron: true,
        onTap: () => Navigator.of(ctx).pop('chat'),
      ),
    ]),
  );
  if (choice == null || !context.mounted) return false;
  await context.push(choice == 'upload' ? target.uploadPath : target.chatPath);
  return true;
}

/// Home's "Make a test": first which class it is for (nothing to ask when there is only one), then how it is made.
Future<bool> makeTest(BuildContext context, List<TestTarget> targets) async {
  if (targets.isEmpty) return false;
  var target = targets.first;
  if (targets.length > 1) {
    final picked = await showCentredCard<TestTarget>(
      context,
      title: 'Make a test',
      subtitle: 'Which class is it for?',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, t) in targets.indexed) ...[
          if (i > 0) const SizedBox(height: 10),
          RowTile(
            leading: Icon(t.isCourse ? Ph.graduationCap : Ph.users, size: 22, color: ink),
            title: t.name,
            meta: t.sizeLabel,
            chevron: true,
            onTap: () => Navigator.of(ctx).pop(t),
          ),
        ],
      ]),
    );
    if (picked == null || !context.mounted) return false;
    target = picked;
  }
  return makeTestFor(context, target);
}
