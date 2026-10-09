import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';
import 'subjects.dart';

/// Students who typed this tuition's join code and wait to be let in. Letting one in also chooses
/// their class and subjects here, so they land in the right groups.
class JoinRequestsScreen extends StatefulWidget {
  const JoinRequestsScreen({super.key});

  @override
  State<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends State<JoinRequestsScreen> with WidgetsBindingObserver, AutoRefresh<JoinRequestsScreen> {
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  Set<Area> get refreshAreas => {Area.students, Area.settings};

  @override
  Duration? get pollEvery => const Duration(seconds: 30);

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
      final r = await api.get('/teacher/join-requests');
      if (mounted) {
        setState(() {
          _rows = (r['requests'] as List).cast<Map<String, dynamic>>();
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _review(Map<String, dynamic> req) async {
    List<Subject> subjects;
    try {
      subjects = await loadSubjects();
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
      return;
    }
    if (!mounted) return;
    int? cls = (req['class_level'] as num?)?.toInt();
    final chosen = <String>{};
    final first = '${req['display_name']}'.split(' ').first;
    final answer = await showCentredCard<String>(
      context,
      title: first,
      subtitle: 'Choose their class and what they study here.',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const FormLabel('Class', top: 4),
          ClassField(value: cls, onChanged: (c) => set(() => cls = c)),
          const FormLabel('Subjects'),
          SubjectToggles(subjects: subjects, value: chosen, onChanged: (v) => set(() {
                chosen
                  ..clear()
                  ..addAll(v);
              })),
          const SizedBox(height: 18),
          PrimaryButton(
            'Let $first in',
            onTap: cls == null || chosen.isEmpty ? null : () => Navigator.of(ctx).pop('accept'),
            disabledReason: cls == null || chosen.isEmpty ? 'Choose a class and at least one subject.' : null,
          ),
          const SizedBox(height: 10),
          SecondaryButton('Decline', tint: danger, onTap: () => Navigator.of(ctx).pop('decline')),
        ]),
      ),
    );
    if (answer == null || !mounted) return;
    try {
      if (answer == 'accept') {
        await api.post('/teacher/join-requests/${req['id']}/accept', {'class_level': cls, 'subject_ids': chosen.toList()});
      } else {
        await api.post('/teacher/join-requests/${req['id']}/decline');
      }
    } on ApiException catch (e) {
      if (mounted) showProblem(context, e);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return PushedPanel(
      kicker: 'Students',
      title: 'Join requests',
      children: [
        const SizedBox(height: 14),
        if (rows == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (rows == null)
          const LoadingState()
        else if (rows.isEmpty)
          const EmptyState(icon: Ph.userPlus, title: 'No requests', body: 'When a student types your join code, they wait here until you let them in.')
        else
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              leading: AppAvatar(name: '${r['display_name']}', seed: '${r['id']}'),
              title: '${r['display_name']}',
              meta: 'Class ${r['class_level']} · asked ${f.when(f.parseTime(r['asked_at']) ?? DateTime.now())}',
              chevron: true,
              onTap: () => _review(r),
            ),
          ],
      ],
    );
  }
}
