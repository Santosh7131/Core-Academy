import 'package:flutter/material.dart';

import '../../core/format.dart' as f;
import '../../theme.dart';
import '../../ui/kit.dart';
import 'start_card.dart';

/// Tests that close sooner first; one with no closing time last.
int soonestClosing(Map<String, dynamic> a, Map<String, dynamic> b) {
  final x = f.parseTime(a['closes_at']);
  final y = f.parseTime(b['closes_at']);
  if (x == null && y == null) return 0;
  if (x == null) return 1;
  if (y == null) return -1;
  return x.compareTo(y);
}

/// A student's tests as sections: the one to write now (a test under way, else the one that closes first), the
/// others that are open, the results, what is coming up and what was missed. The home screen shows the class's
/// tests this way and a course's page shows the course's. The caller wraps the list in `staggered`.
///
/// [onStart] is for a tap on a test to write, [onOpen] for a path to push (a result). With [onAllResults] the
/// results show the latest three and a link to all of them; without it a long list shows every result. [side] is
/// the space at each side: the screen's gutter, or 0 inside a panel that has one already.
List<Widget> testSections(
  BuildContext context,
  List<Map<String, dynamic>> tests, {
  required ValueChanged<Map<String, dynamic>> onStart,
  required ValueChanged<String> onOpen,
  VoidCallback? onAllResults,
  double side = gutter,
  String emptyTitle = 'No tests yet',
  String emptyBody = 'When your tutor gives you a test, it shows up here.',
}) {
  List<Map<String, dynamic>> of(String s) => tests.where((t) => t['state'] == s).toList();
  final writing = of('in_progress');
  final open = of('open')..sort(soonestClosing);
  final upcoming = of('upcoming');
  final done = of('done');
  final missed = of('missed');
  if (tests.isEmpty) {
    return [
      const SizedBox(height: 40),
      EmptyState(icon: Ph.exam, title: emptyTitle, body: emptyBody),
    ];
  }

  // The one thing to do now: a test under way, else the one that closes first.
  final current = [...writing, ...open];
  final hero = current.isEmpty ? null : current.first;
  final more = current.length > 1 ? current.sublist(1) : const <Map<String, dynamic>>[];

  String facts(Map<String, dynamic> t) {
    final parts = <String>[f.count(t['question_count'] as int, 'question')];
    if (t['time_limit_min'] != null) parts.add('${t['time_limit_min']} min');
    return parts.join(' · ');
  }

  Widget group(String label, int count, List<Widget> rows, {bool alert = false, Widget? trailing}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionRule(label, count: count, alert: alert, trailing: trailing, padding: EdgeInsets.fromLTRB(side, 22, side, 11)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: Column(children: [
            for (final (i, r) in rows.indexed) ...[if (i > 0) const SizedBox(height: gapRow), r],
          ]),
        ),
      ]);

  Widget openRow(Map<String, dynamic> t) {
    final resume = t['state'] == 'in_progress';
    final closes = f.parseTime(t['closes_at']);
    return RowTile(
      title: '${t['title']}',
      meta: resume ? 'Under way · tap to continue' : (closes == null ? facts(t) : '${facts(t)} · closes ${f.when(closes)}'),
      trailing: resume ? const TagChip('Resume', tone: Tone.warning) : null,
      chevron: !resume,
      onTap: () => onStart(t),
    );
  }

  return [
    Padding(
      padding: EdgeInsets.fromLTRB(side, 22, side, 0),
      child: hero == null ? AllCaughtUp(next: upcoming.isEmpty ? null : upcoming.first) : TestHero(test: hero, onStart: () => onStart(hero)),
    ),
    if (more.isNotEmpty) group('Also open', more.length, [for (final t in more) openRow(t)]),
    if (done.isNotEmpty)
      group(
        'Results',
        done.length,
        [
          for (final t in (onAllResults == null ? done : done.take(3)))
            Builder(builder: (context) {
              final a = t['attempt'] as Map<String, dynamic>;
              final submitted = f.parseTime(a['submitted_at']);
              // Marks stay hidden until the test closes, everyone has finished, or the tutor shows them.
              final open = t['results_open'] != false;
              final closes = f.parseTime(t['closes_at']);
              return RowTile(
                title: '${t['title']}',
                meta: !open
                    ? 'Submitted · marks ${closes == null ? 'soon' : 'after ${f.when(closes)}'}'
                    : (submitted == null ? null : 'Submitted ${f.when(submitted)}'),
                trailing: open ? Text('${f.marks(a['score'])}/${f.marks(a['max_score'])}', style: numStyle(size: 15)) : const TagChip('Marks later'),
                onTap: open ? () => onOpen('/s/result/${a['id']}') : null,
              );
            }),
        ],
        trailing: onAllResults == null
            ? null
            : Pressable(
                label: 'All results',
                onTap: onAllResults,
                child: Text('All results', style: chipStyle.copyWith(color: muted, fontWeight: FontWeight.w600)),
              ),
      ),
    if (upcoming.isNotEmpty)
      group('Coming up', upcoming.length, [
        for (final t in upcoming)
          RowTile(
            title: '${t['title']}',
            meta: 'Opens ${f.parseTime(t['opens_at']) == null ? '' : f.when(f.parseTime(t['opens_at'])!)} · ${facts(t)}',
          ),
      ]),
    if (missed.isNotEmpty)
      group('Missed', missed.length, [
        for (final t in missed)
          RowTile(title: '${t['title']}', meta: f.parseTime(t['closes_at']) == null ? null : 'Closed ${f.when(f.parseTime(t['closes_at'])!)}'),
      ], alert: true),
  ];
}
