import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  List<Map<String, dynamic>>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await api.get('/student/results');
      if (mounted) setState(() => _rows = (r['results'] as List).cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return PushedPanel(
      kicker: rows == null ? null : '${rows.length} tests written',
      title: 'My results',
      children: [
        const SizedBox(height: 22),
        if (rows == null && _error != null)
          ErrorState(message: _error!, onRetry: _load)
        else if (rows == null)
          const LoadingState()
        else if (rows.isEmpty)
          EmptyState(icon: Ph.exam, title: 'No results yet', body: 'Your marks show up here after you submit a test.')
        else
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) const SizedBox(height: gapRow),
            RowTile(
              title: '${r['title']}${(r['attempt_no'] as int) > 1 ? ' (retake)' : ''}',
              meta: 'Submitted ${f.when(f.parseTime(r['submitted_at'])!)}',
              trailing: Text('${f.marks(r['score'])}/${f.marks(r['max_score'])}', style: numStyle(size: 15)),
              onTap: () => context.push('/s/result/${r['id']}'),
            ),
          ],
      ],
    );
  }
}
