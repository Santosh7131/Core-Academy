import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/changes.dart';
import '../../core/format.dart' as f;
import '../../core/levels.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import 'common.dart';
import 'make_tests_screen.dart' show WhenToPost, askWhenToPost;
import 'paper_runner.dart' show suggestedLimit;

int _n(Object? v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;

bool _isCourse(Map<String, dynamic> p) => p['course_id'] != null;

/// Which class or course a paper is for, as one filter value: `class:9` or `course:<id>`.
String _placeKey(Map<String, dynamic> p) => _isCourse(p) ? 'course:${p['course_id']}' : 'class:${p['class_level']}';

String _placeName(Map<String, dynamic> p) => _isCourse(p) ? '${p['course'] ?? 'Course'}' : className(p['class_level']);

/// What a paper is for: "9th Maths", or the name of its course.
String _forWhom(Map<String, dynamic> p) {
  if (_isCourse(p)) return '${p['course'] ?? 'Course'}';
  final subject = p['subject'];
  return subject == null ? className(p['class_level']) : groupName(_n(p['class_level']), '$subject');
}

/// When a paper was given, and how often: "Given Thu 29 Oct", "Given 3 times · last Thu 29 Oct". A paper whose latest test has not
/// opened yet is "coming up" (or its "next" time).
String _given(Map<String, dynamic> p) {
  final at = f.parseTime(p['last_given']);
  final uses = _n(p['uses']);
  final ahead = at != null && at.isAfter(DateTime.now());
  final day = at == null ? '' : f.dayDate(at);
  if (uses <= 1) return at == null ? '' : '${ahead ? 'Coming up' : 'Given'} $day';
  return 'Given ${f.count(uses, 'time')}${at == null ? '' : ' · ${ahead ? 'next' : 'last'} $day'}';
}

/// What the card that says a test is posted tells: when it opens and closes (the day only once when both are on one day).
String _postedLine(WhenToPost w) {
  final opens = w.opens;
  final sameDay = opens != null && DateUtils.isSameDay(opens, w.closes);
  final closes = sameDay ? 'closes at ${f.time(w.closes)}' : 'closes ${f.whenDate(w.closes)}';
  return '${w.name} ${opens == null ? 'is open now' : 'opens ${f.whenDate(opens)}'} and $closes. Students are told when it opens.';
}

/// The Bank tab: every paper the tutor has posted, once each, kept so it can be posted again. Narrowed by class (or course) and by
/// subject; a tap on a paper asks when to post it again and posts it as a new test. Nothing is saved by hand: the server lists the
/// tests that were posted (GET /teacher/bank).
class BankScreen extends StatefulWidget {
  const BankScreen({super.key});

  @override
  State<BankScreen> createState() => _BankScreenState();
}

class _BankScreenState extends State<BankScreen> with WidgetsBindingObserver, AutoRefresh<BankScreen> {
  List<Map<String, dynamic>>? _papers;
  String? _error;

  /// The filters: a class or course (`class:9`, `course:<id>`) and a subject id. Null is "all".
  String? _place;
  String? _subject;

  /// The paper being posted again: a second one cannot be started until it is done.
  String? _posting;

  @override
  Set<Area> get refreshAreas => {Area.tests, Area.courses, Area.settings};

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
      final d = await api.get('/teacher/bank');
      if (!mounted) return;
      final papers = (d['papers'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _papers = papers;
        _error = null;
        // A filter that no paper has any more (its tests were deleted) is dropped, so the list is never empty for it.
        if (_place != null && !papers.any((p) => _placeKey(p) == _place)) _place = null;
        if (_subject != null && !_inPlace(papers).any((p) => !_isCourse(p) && '${p['subject_id']}' == _subject)) _subject = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// The papers of the class or course chosen (all of them when none is).
  List<Map<String, dynamic>> _inPlace(List<Map<String, dynamic>> all) => _place == null ? all : [for (final p in all) if (_placeKey(p) == _place) p];

  List<Map<String, dynamic>> _visible(List<Map<String, dynamic>> all) =>
      [for (final p in _inPlace(all)) if (_subject == null || (!_isCourse(p) && '${p['subject_id']}' == _subject)) p];

  // ---------------------------------------------------------------- filters

  String _placeAll(List<Map<String, dynamic>> all) {
    final courses = all.where(_isCourse).length;
    if (courses == 0) return 'All classes';
    return courses == all.length ? 'All courses' : 'All classes & courses';
  }

  Future<void> _pickPlace(List<Map<String, dynamic>> all) async {
    final names = <String, String>{};
    final counts = <String, int>{};
    final order = <String, (int, String)>{};
    for (final p in all) {
      final k = _placeKey(p);
      names[k] = _placeName(p);
      counts[k] = (counts[k] ?? 0) + 1;
      // Classes in order, then courses by name.
      order[k] = (_isCourse(p) ? 1 << 20 : _n(p['class_level']), names[k]!);
    }
    final keys = counts.keys.toList()
      ..sort((a, b) {
        final x = order[a]!, y = order[b]!;
        return x.$1 != y.$1 ? x.$1.compareTo(y.$1) : x.$2.compareTo(y.$2);
      });
    final c = await showChoices<String>(
      context,
      title: 'Class',
      options: [Choice<String>(null, _placeAll(all), count: all.length), for (final k in keys) Choice<String>(k, names[k]!, count: counts[k])],
      selected: _place,
    );
    if (c == null || !mounted) return;
    setState(() {
      _place = c.value;
      // A subject this class does not have is dropped.
      if (_subject != null && !_inPlace(all).any((p) => !_isCourse(p) && '${p['subject_id']}' == _subject)) _subject = null;
    });
  }

  Future<void> _pickSubject(List<Map<String, dynamic>> all) async {
    final names = <String, String>{};
    final counts = <String, int>{};
    for (final p in _inPlace(all)) {
      if (_isCourse(p)) continue;
      final k = '${p['subject_id']}';
      names[k] = '${p['subject'] ?? 'No subject'}';
      counts[k] = (counts[k] ?? 0) + 1;
    }
    final keys = counts.keys.toList()..sort((a, b) => names[a]!.compareTo(names[b]!));
    final c = await showChoices<String>(
      context,
      title: 'Subject',
      options: [Choice<String>(null, 'All subjects', count: counts.values.fold<int>(0, (s, n) => s + n)), for (final k in keys) Choice<String>(k, names[k]!, count: counts[k])],
      selected: _subject,
    );
    if (c != null && mounted) setState(() => _subject = c.value);
  }

  // ---------------------------------------------------------------- posting again

  /// Asks when to post the paper again, then makes its test from the questions of the paper's latest one and posts it. The audience is
  /// what that test had: its group, its course, or the students chosen one by one.
  Future<void> _postAgain(Map<String, dynamic> p) async {
    if (_posting != null) return;
    final who = _isCourse(p)
        ? 'Goes to everyone in the course'
        : p['assign_group'] == true || p['assign_all'] == true
            ? 'Goes to the whole group'
            : 'Goes to the ${f.count(_n(p['chosen']), 'student')} chosen before';
    final when = await askWhenToPost(
      context,
      name: '${p['title']}',
      subtitle: '${_forWhom(p)} · ${f.count(_n(p['question_count']), 'question')}\n$who',
      opened: f.parseTime(p['opens_at']),
      closed: f.parseTime(p['closes_at']),
      limit: p['time_limit_min'] as int?,
      shuffle: p['shuffle'] != false,
    );
    if (when == null || !mounted) return;
    setState(() => _posting = '${p['id']}');
    String? posted;
    try {
      posted = await _post(p, when);
    } on ApiException catch (e) {
      if (mounted) await showProblem(context, e);
    } catch (_) {
      if (mounted) await showProblem(context, StateError('could not post'));
    } finally {
      if (mounted) setState(() => _posting = null);
    }
    if (posted == null || !mounted) return;
    final open = await showCentredCard<bool>(
      context,
      title: 'Posted',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Fig(_postedLine(when), style: bodyStyle),
        const SizedBox(height: 18),
        PrimaryButton('OK', onTap: () => Navigator.of(ctx).pop(false)),
        const SizedBox(height: 8),
        Center(child: TextAction('Open the test', onTap: () => Navigator.of(ctx).pop(true))),
      ]),
    );
    if (open == true && mounted) await context.push('/t/tests/$posted');
  }

  /// Makes the new test and posts it; returns its id. A test that was made but could not be posted is taken away again, so no draft
  /// nobody asked for is left on Home.
  Future<String> _post(Map<String, dynamic> p, WhenToPost when) async {
    final d = await api.get('/teacher/tests/${p['id']}');
    final t = Map<String, dynamic>.from(d['test'] as Map);
    final questions = (d['questions'] as List).cast<Map<String, dynamic>>();
    final students = (d['students'] as List).cast<Map<String, dynamic>>();
    final course = t['course_id'] as String?;
    final group = t['assign_group'] == true || t['assign_all'] == true;
    final made = await api.post('/teacher/tests', {
      'title': when.name,
      'question_ids': [for (final q in questions) q['id']],
      'time_limit_min': when.limit ?? suggestedLimit(questions.length),
      if (when.opens != null) 'opens_at': when.opens!.toUtc().toIso8601String(),
      'closes_at': when.closes.toUtc().toIso8601String(),
      'shuffle': when.shuffle,
      if (t['paper_id'] != null) 'paper_id': t['paper_id'],
      if (course != null)
        'course_id': course
      else ...{
        'class_level': t['class_level'],
        'subject_id': t['subject_id'],
        'assign_all': false,
        'assign_group': group,
        'student_ids': group ? <String>[] : [for (final s in students) s['id']],
      },
    });
    final id = '${made['id']}';
    try {
      await api.post('/teacher/tests/$id/publish', {'published': true});
    } catch (_) {
      try {
        await api.delete('/teacher/tests/$id');
      } catch (_) {
        // It stays a draft on Home; the problem shown is the one that matters.
      }
      rethrow;
    }
    return id;
  }

  // ---------------------------------------------------------------- build

  String _kicker(List<Map<String, dynamic>>? all, List<Map<String, dynamic>> shown) {
    if (all == null || all.isEmpty) return 'Saved papers';
    return shown.length == all.length ? f.count(all.length, 'paper') : '${shown.length} of ${f.count(all.length, 'paper')}';
  }

  @override
  Widget build(BuildContext context) {
    final all = _papers;
    final shown = all == null ? const <Map<String, dynamic>>[] : _visible(all);
    return SafeArea(
      bottom: false,
      child: PullToRefresh(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.zero, physics: const AlwaysScrollableScrollPhysics(), children: [
          TabHeader(kicker: _kicker(all, shown), title: 'Bank'),
          if (all == null && _error != null)
            ErrorState(message: _error!, onRetry: _load)
          else if (all == null)
            const LoadingState(inset: true, rows: 4)
          else if (all.isEmpty)
            const EmptyState(
              icon: Ph.bank,
              title: 'Nothing in the Bank yet',
              body: 'Every test you post is kept here, so you can post it again another week or for another class.',
            )
          else
            ..._list(all, shown),
          navClearance,
        ]),
      ),
    );
  }

  List<Widget> _list(List<Map<String, dynamic>> all, List<Map<String, dynamic>> shown) {
    final placeLabel = _place == null ? _placeAll(all) : _placeName(all.firstWhere((p) => _placeKey(p) == _place));
    final inPlace = _inPlace(all);
    final subjectName = _subject == null ? null : inPlace.where((p) => '${p['subject_id']}' == _subject).map((p) => '${p['subject']}').firstOrNull;
    final hasGroups = inPlace.any((p) => !_isCourse(p));
    // The filters only offer what the papers have, so some paper always fits them.
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(gutter, 12, gutter, 14),
        child: Fig('Every test you post is kept here. Tap one to post it again.', style: bodyStyle.copyWith(color: muted)),
      ),
      FilterBar(children: [
        SelectPill(label: placeLabel, active: _place != null, onTap: () => _pickPlace(all)),
        if (hasGroups) SelectPill(label: subjectName ?? 'All subjects', active: _subject != null, onTap: () => _pickSubject(all)),
      ]),
      if (_posting != null)
        const Padding(
          padding: EdgeInsets.fromLTRB(gutter, 14, gutter, 0),
          child: InlineNotice('Posting the test…', tone: Tone.neutral),
        ),
      ...staggered([
        const SizedBox(height: 14),
        for (final (i, p) in shown.indexed) ...[
          if (i > 0) const SizedBox(height: gapRow),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: gutter),
            child: TaggedRow(
              title: '${p['title']}',
              meta: [
                '${_forWhom(p)} · ${f.count(_n(p['question_count']), 'question')}',
                _given(p),
              ].where((s) => s.isNotEmpty).join('\n'),
              chevron: true,
              onTap: _posting == null ? () => _postAgain(p) : null,
            ),
          ),
        ],
      ], scope: this, prefix: 'bank', stepMs: 50),
    ];
  }
}
