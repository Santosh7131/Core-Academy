import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';

/// A subject the tuition teaches. A group is a class and a subject, such as "10th Science".
class Subject {
  const Subject(this.id, this.name, {this.isDefault = false});

  factory Subject.fromJson(Map<String, dynamic> j) => Subject('${j['id']}', '${j['name']}', isDefault: j['is_default'] == true);

  final String id;
  final String name;

  /// Maths: what older app versions and pre-subject data default to.
  final bool isDefault;
}

Future<List<Subject>> loadSubjects() async {
  final r = await api.get('/teacher/subjects');
  return [for (final s in r['subjects'] as List) Subject.fromJson(Map<String, dynamic>.from(s))];
}

/// "10th Science". Every class the tuition teaches, 6 to 12, takes "th".
String groupName(int classLevel, String subject) => '${classLevel}th $subject';

/// The subject names in a student row from the API: [{id, name}, ...].
List<String> subjectNames(Object? list) => [for (final s in (list as List? ?? const [])) '${(s as Map)['name']}'];

/// One subject at a time, optionally with "All subjects".
class SubjectChips extends StatelessWidget {
  const SubjectChips({
    super.key,
    required this.subjects,
    required this.value,
    required this.onChanged,
    this.allowAll = false,
    this.counts,
    this.padding = const EdgeInsets.symmetric(horizontal: gutter),
  });

  final List<Subject> subjects;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool allowAll;

  /// Optional number beside each subject, by subject id.
  final Map<String, int>? counts;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ChipRow(padding: padding, children: [
        if (allowAll) SegChip('All subjects', selected: value == null, onTap: () => onChanged(null)),
        for (final s in subjects) SegChip(s.name, selected: value == s.id, count: counts?[s.id], onTap: () => onChanged(s.id)),
      ]);
}

/// Several subjects at once: the ones a student studies.
class SubjectToggles extends StatelessWidget {
  const SubjectToggles({super.key, required this.subjects, required this.value, required this.onChanged});

  final List<Subject> subjects;
  final Set<String> value;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in subjects)
          SegChip(s.name, selected: value.contains(s.id), onTap: () {
            final next = {...value};
            if (!next.remove(s.id)) next.add(s.id);
            onChanged(next);
          }),
      ]);
}
