import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../ui/kit.dart';

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

Future<Choice<String>?> _pickSubject(BuildContext context, List<Subject> subjects, String? value,
        {required bool allowAll, Map<String, int>? counts}) =>
    showChoices<String>(
      context,
      title: 'Subject',
      options: [
        if (allowAll) const Choice(null, 'All subjects'),
        for (final s in subjects) Choice(s.id, s.name, count: counts?[s.id]),
      ],
      selected: value,
    );

/// The subject as a filter pill: "All subjects" or "Science".
class SubjectFilter extends StatelessWidget {
  const SubjectFilter({super.key, required this.subjects, required this.value, required this.onChanged, this.allowAll = true, this.counts});

  final List<Subject> subjects;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool allowAll;

  /// Optional number beside each subject in the choices, by subject id.
  final Map<String, int>? counts;

  @override
  Widget build(BuildContext context) {
    final current = subjects.where((s) => s.id == value).map((s) => s.name).firstOrNull;
    return SelectPill(
      label: current ?? 'All subjects',
      active: current != null,
      onTap: () async {
        final c = await _pickSubject(context, subjects, value, allowAll: allowAll, counts: counts);
        if (c != null) onChanged(c.value);
      },
    );
  }
}

/// The subject in a form.
class SubjectField extends StatelessWidget {
  const SubjectField({super.key, required this.subjects, required this.value, required this.onChanged, this.enabled = true});

  final List<Subject> subjects;
  final String? value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => SelectField(
        value: subjects.where((s) => s.id == value).map((s) => s.name).firstOrNull,
        placeholder: 'Choose a subject',
        onTap: !enabled
            ? null
            : () async {
                final c = await _pickSubject(context, subjects, value, allowAll: false);
                if (c?.value != null) onChanged(c!.value!);
              },
      );
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
