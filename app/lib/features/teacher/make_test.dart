import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/format.dart' as f;
import '../../core/levels.dart';

String _enc(String s) => Uri.encodeComponent(s);

/// Who new tests are for: a group (a class and a subject) or a course. Making tests starts the same way for both, so every
/// "Make tests" button, on Home and on a group's or a course's page, goes through here.
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

  String get chatPath => isCourse ? '/t/courses/$courseId/chat?name=${_enc(plainName)}' : '/t/groups/$classLevel/$subjectId/chat?name=${_enc(plainName)}';

  static int _int(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
}

/// What the Make tests screen opens with: the class when it is known (from a class's own page), or the classes to choose from.
class MakeTests {
  const MakeTests({this.target, this.targets = const []});
  final TestTarget? target;
  final List<TestTarget> targets;
}

/// Opens Make tests for one class. Returns true when the tutor has come back from it, so the screen can load again.
Future<bool> makeTestFor(BuildContext context, TestTarget target) async {
  await context.push('/t/make', extra: MakeTests(target: target));
  return true;
}

/// Home's "Make tests": the tutor chooses the class first (nothing to ask when there is only one).
Future<bool> makeTest(BuildContext context, List<TestTarget> targets) async {
  if (targets.isEmpty) return false;
  await context.push('/t/make', extra: MakeTests(targets: targets));
  return true;
}
