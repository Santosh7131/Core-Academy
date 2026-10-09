import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';
import 'subjects.dart';

/// A group a new tuition starts with: a class, and a subject that is either a standard one ([id]) or
/// one the tutor typed ([id] null).
class _Group {
  const _Group(this.classLevel, this.name, [this.id]);
  final int classLevel;
  final String name;
  final String? id;

  String get label => groupName(classLevel, name);

  Map<String, dynamic> toJson() => {'class_level': classLevel, if (id != null) 'subject_id': id else 'subject_name': name};
}

/// First run for a tutor with no tuition: name it and say what they teach. Everything else (students,
/// tests) happens inside the groups afterwards.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _name = TextEditingController();
  final List<_Group> _groups = [];
  List<Subject> _standard = [];
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
    _loadSubjects();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _loadSubjects() async {
    try {
      final r = await api.get('/auth/standard-subjects');
      if (mounted) setState(() => _standard = [for (final s in r['subjects'] as List) Subject.fromJson(Map<String, dynamic>.from(s))]);
    } on ApiException {
      // The tutor can still type a subject by hand.
    }
  }

  Future<String?> _askSubjectName() {
    final c = TextEditingController();
    return showCentredCard<String>(
      context,
      title: 'Another subject',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GroupedInputs(children: [
          BareField(
            controller: c,
            placeholder: 'Subject name, e.g. Accountancy',
            autofocus: true,
            capitalization: TextCapitalization.words,
            onSubmitted: (v) => Navigator.of(ctx).pop(v),
          ),
        ]),
        const SizedBox(height: 16),
        PrimaryButton('Use this subject', onTap: () => Navigator.of(ctx).pop(c.text)),
      ]),
    );
  }

  static const _other = '+other';

  Future<void> _addGroup() async {
    int? cls;
    Subject? subject;
    final ok = await showCentredCard<bool>(
      context,
      title: 'Add a class and subject',
      subtitle: 'A group is one class learning one subject, like 10th Maths.',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          final ready = cls != null && subject != null;
          return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const FormLabel('Class', top: 4),
            ClassField(value: cls, onChanged: (c) => set(() => cls = c)),
            const FormLabel('Subject'),
            SelectField(
              value: subject?.name,
              placeholder: 'Choose a subject',
              onTap: () async {
                final c = await showChoices<String>(
                  ctx,
                  title: 'Subject',
                  options: [for (final s in _standard) Choice(s.id, s.name), const Choice(_other, 'Another subject')],
                  selected: subject?.id,
                );
                if (c?.value == null || !ctx.mounted) return;
                if (c!.value != _other) {
                  set(() => subject = _standard.firstWhere((s) => s.id == c.value));
                  return;
                }
                final typed = (await _askSubjectName())?.trim();
                if (typed != null && typed.isNotEmpty) {
                  // A name a standard subject already has is that subject.
                  final known = _standard.where((s) => s.name.toLowerCase() == typed.toLowerCase()).firstOrNull;
                  set(() => subject = known ?? Subject('', typed));
                }
              },
            ),
            const SizedBox(height: 18),
            PrimaryButton(
              'Add group',
              onTap: ready ? () => Navigator.of(ctx).pop(true) : null,
              disabledReason: ready ? null : 'Choose a class and a subject.',
            ),
          ]);
        },
      ),
    );
    if (ok != true || cls == null || subject == null) return;
    final g = _Group(cls!, subject!.name, subject!.id.isEmpty ? null : subject!.id);
    if (_groups.any((x) => x.classLevel == g.classLevel && x.name.toLowerCase() == g.name.toLowerCase())) return;
    setState(() => _groups.add(g));
  }

  Future<void> _create() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await session.createTuition(_name.text, [for (final g in _groups) g.toJson()]);
      if (!mounted) return;
      // On to the join code first; only then does the router know the tutor has a tuition.
      context.go('/t/code?first=1');
      session.changed();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final named = _name.text.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.fromLTRB(gutter, 30, gutter, 28), children: [
          const Kicker('Set up'),
          const SizedBox(height: 6),
          Text('Your tuition', style: displayStyle),
          const SizedBox(height: 10),
          Fig('Students see this name. You can change it later in Settings.', style: bodyStyle.copyWith(color: muted)),
          const SizedBox(height: 22),
          GroupedInputs(children: [
            BareField(controller: _name, placeholder: 'Tuition name, e.g. Priya Maths Classes', capitalization: TextCapitalization.words),
          ]),
          SectionRule('What you teach', count: _groups.length, padding: const EdgeInsets.fromLTRB(0, 28, 0, 11)),
          if (_groups.isEmpty)
            Fig('Add the classes and subjects you teach. Each one becomes a group, where you add students and make tests.',
                style: bodyStyle.copyWith(color: muted))
          else
            for (final (i, g) in _groups.indexed) ...[
              if (i > 0) const SizedBox(height: gapRow),
              RowTile(
                title: g.label,
                trailing: TextAction('Remove', onTap: () => setState(() => _groups.remove(g))),
              ),
            ],
          const SizedBox(height: 14),
          SecondaryButton('Add a class and subject', icon: Ph.plus, onTap: _addGroup),
          if (_error != null) ...[const SizedBox(height: 18), InlineNotice(_error!, icon: Ph.warning)],
          const SizedBox(height: 26),
          PrimaryButton(
            _busy ? 'Creating' : 'Create my tuition',
            onTap: !named || _busy ? null : _create,
            disabledReason: named ? null : 'Type a name for your tuition.',
          ),
          const SizedBox(height: 10),
          Center(
            child: TextAction('Log out', onTap: () async {
              final ok = await confirmCard(context, title: 'Log out?', body: 'Your account stays. You can log in again and finish setting up.', confirm: 'Log out', destructive: true);
              if (ok) session.logout();
            }),
          ),
        ]),
      ),
    );
  }
}
