import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/format.dart' as f;
import '../../core/pending_answers.dart';
import '../../theme.dart';
import '../../ui/kit.dart';
import '../../ui/math_text.dart';
import '../../ui/tokens.dart';

class _Q {
  _Q(Map<String, dynamic> j)
      : id = j['id'] as String,
        n = j['n'] as int,
        text = j['text'] as String,
        imageUrl = j['image_url'] as String?,
        options = (j['options'] as List).cast<String>(),
        chosen = j['chosen'] as int?,
        flagged = j['flagged'] == true;
  final String id;
  final int n;
  final String text;
  final String? imageUrl;
  final List<String> options;
  int? chosen;
  bool flagged;
}

/// Direction A, "Paper": the question owns the page, time is a quiet pill top right.
/// No right/wrong feedback until submit; every choice is saved straight away.
class TestScreen extends StatefulWidget {
  const TestScreen({super.key, required this.testId});
  final String testId;

  @override
  State<TestScreen> createState() => _TestScreenState();
}

class _TestScreenState extends State<TestScreen> {
  String? _attemptId;
  String _title = '';
  DateTime? _deadline;
  Duration _clockSkew = Duration.zero; // server time minus phone time
  List<_Q> _qs = [];
  int _i = 0;
  String? _error;

  Map<String, Map<String, dynamic>> _pending = {};
  Timer? _flushTimer;
  Timer? _ticker;
  bool _flushing = false;
  bool _offline = false;
  bool _submitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() => _error = null);
    try {
      final r = await api.post('/student/tests/${widget.testId}/start');
      final a = r['attempt'] as Map<String, dynamic>;
      final serverNow = DateTime.parse('${a['server_now']}');
      _clockSkew = serverNow.difference(DateTime.now().toUtc());
      _attemptId = a['id'] as String;
      _title = '${a['title']}';
      _deadline = f.parseTime(a['deadline_at']);
      _qs = (r['questions'] as List).map((j) => _Q(j as Map<String, dynamic>)).toList();
      // Answers made offline are newer than what the server has.
      _pending = PendingAnswers.load(_attemptId!);
      for (final q in _qs) {
        final p = _pending[q.id];
        if (p != null) {
          q.chosen = p['choice'] as int?;
          q.flagged = p['flagged'] == true;
        }
      }
      _i = _qs.indexWhere((q) => q.chosen == null);
      if (_i < 0) _i = 0;
      setState(() {});
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
      _flush();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Duration? get _left => _deadline?.difference(DateTime.now().add(_clockSkew));

  void _tick() {
    final left = _left;
    if (left == null || !mounted) return;
    if (left <= Duration.zero && !_submitting) {
      _submit(auto: true);
    } else {
      setState(() {});
    }
  }

  void _record(_Q q) {
    _pending[q.id] = {'choice': q.chosen, 'flagged': q.flagged};
    PendingAnswers.save(_attemptId!, _pending);
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 400), _flush);
  }

  Future<void> _flush() async {
    if (_flushing || _pending.isEmpty || _attemptId == null || _submitting) return;
    _flushing = true;
    final sent = {for (final e in _pending.entries) e.key: Map<String, dynamic>.from(e.value)};
    try {
      await api.put('/student/attempts/$_attemptId/answers', {
        'answers': [
          for (final e in sent.entries) {'question_id': e.key, 'choice': e.value['choice'], 'flagged': e.value['flagged']},
        ],
      });
      // Drop only what is unchanged since it was sent.
      for (final e in sent.entries) {
        final now = _pending[e.key];
        if (now != null && now['choice'] == e.value['choice'] && now['flagged'] == e.value['flagged']) _pending.remove(e.key);
      }
      await PendingAnswers.save(_attemptId!, _pending);
      if (mounted && _offline) setState(() => _offline = false);
    } on ApiException catch (e) {
      if (e.code == 'time_up' || e.code == 'submitted') {
        await PendingAnswers.clear(_attemptId!);
        if (mounted) context.pushReplacement('/s/result/$_attemptId?auto=1');
        return;
      }
      if (mounted) setState(() => _offline = true);
      _flushTimer?.cancel();
      _flushTimer = Timer(const Duration(seconds: 5), _flush);
    } finally {
      _flushing = false;
    }
    if (_pending.isNotEmpty && !_offline) _flush();
  }

  Future<void> _submit({bool auto = false}) async {
    if (_submitting || _attemptId == null) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    _flushTimer?.cancel();
    try {
      await api.post('/student/attempts/$_attemptId/submit', {
        'auto': auto,
        'answers': [
          for (final e in _pending.entries) {'question_id': e.key, 'choice': e.value['choice'], 'flagged': e.value['flagged']},
        ],
      });
      await PendingAnswers.clear(_attemptId!);
      _ticker?.cancel();
      if (mounted) context.pushReplacement('/s/result/$_attemptId${auto ? '?auto=1' : ''}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = e.offline
            ? 'Could not submit: no internet. Your answers are safe on this phone. Try again when you are connected.'
            : e.message;
      });
      if (auto) Timer(const Duration(seconds: 5), () => _submit(auto: true));
    }
  }

  void _choose(int i) {
    final q = _qs[_i];
    setState(() => q.chosen = i);
    _record(q);
  }

  void _clear() {
    final q = _qs[_i];
    setState(() => q.chosen = null);
    _record(q);
  }

  void _toggleFlag() {
    final q = _qs[_i];
    setState(() => q.flagged = !q.flagged);
    _record(q);
  }

  void _go(int i) {
    if (i < 0 || i >= _qs.length) return;
    setState(() => _i = i);
  }

  Future<void> _leave() async {
    final ok = await confirmCard(
      context,
      title: 'Leave the test?',
      body: _deadline == null
          ? 'Your answers are saved. You can come back and finish it later.'
          : 'Your answers are saved, but the timer keeps running while you are away.',
      confirm: 'Leave',
      cancel: 'Keep writing',
    );
    if (ok && mounted) {
      _flush();
      context.go('/s');
    }
  }

  Future<void> _askSubmit() async {
    final answered = _qs.where((q) => q.chosen != null).length;
    final flagged = _qs.where((q) => q.flagged).length;
    final left = _qs.length - answered;
    final ok = await confirmCard(
      context,
      title: 'Submit your test?',
      body: [
        '$answered of ${_qs.length} answered.',
        if (left > 0) '$left not answered yet.',
        if (flagged > 0) '$flagged flagged for review.',
        'You cannot change answers after you submit.',
      ].join(' '),
      confirm: 'Submit',
      cancel: 'Keep writing',
    );
    if (ok) _submit();
  }

  Future<void> _openMap() async {
    final jump = await showCentredCard<int>(
      context,
      title: 'All questions',
      builder: (ctx) => SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (i, q) in _qs.indexed)
              Pressable(
                onTap: () => Navigator.of(ctx).pop(i),
                label: 'Question ${q.n}',
                child: _MapChip(n: q.n, current: i == _i, answered: q.chosen != null, flagged: q.flagged),
              ),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 16, runSpacing: 6, children: const [
            _Legend(kind: _LegendKind.answered, label: 'Answered'),
            _Legend(kind: _LegendKind.flagged, label: 'Flagged'),
            _Legend(kind: _LegendKind.open, label: 'Not answered'),
          ]),
          const SizedBox(height: 20),
          PrimaryButton('Submit test', onTap: () => Navigator.of(ctx).pop(-1)),
        ]),
      ),
    );
    if (jump == null || !mounted) return;
    if (jump == -1) {
      _askSubmit();
    } else {
      _go(jump);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_attemptId == null) {
      return Scaffold(
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
              child: Row(children: [CircleBtn(icon: Ph.x, label: 'Close', onTap: () => context.go('/s'))]),
            ),
            Expanded(
              child: Center(
                child: _error != null ? ErrorState(message: _error!, onRetry: _start) : const LoadingState(text: 'Opening your test'),
              ),
            ),
          ]),
        ),
      );
    }

    final q = _qs[_i];
    final answered = _qs.where((x) => x.chosen != null).length;
    final flagged = _qs.where((x) => x.flagged).length;
    final left = _left;
    final low = left != null && left.inMinutes < 5;
    final isLast = _i == _qs.length - 1;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
              child: Row(children: [
                CircleBtn(icon: Ph.x, label: 'Leave test', onTap: _leave),
                const Spacer(),
                if (left != null)
                  Container(
                    height: 34,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: low
                        ? BoxDecoration(color: warningSoft, borderRadius: BorderRadius.circular(rPill))
                        : surface(radius: rPill, shadow: e1),
                    child: Row(children: [
                      Icon(Ph.timer, size: 16, color: low ? warning : ink),
                      const SizedBox(width: 6),
                      Text(f.clock(left), style: numStyle(size: 14, color: low ? warning : ink)),
                    ]),
                  ),
                const SizedBox(width: 10),
                CircleBtn(icon: Ph.listNumbers, label: 'All questions', onTap: _openMap),
              ]),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v < -300) _go(_i + 1);
                  if (v > 300) _go(_i - 1);
                },
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 20),
                  children: [
                    SectionRule(_title, padding: const EdgeInsets.fromLTRB(0, 22, 0, 14)),
                    Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Text('Question ', style: displayStyle),
                      Text(q.n.toString().padLeft(2, '0'), style: numStyle(size: 38, weight: FontWeight.w800)),
                      Text('/${_qs.length}', style: numStyle(size: 20, weight: FontWeight.w600, color: faint)),
                    ]),
                    const SizedBox(height: 10),
                    Fig('$answered answered · $flagged flagged · ${_qs.length - answered} to go', style: labelStyle, numColor: ink),
                    if (_offline) ...[
                      const SizedBox(height: 14),
                      InlineNotice('No internet. Your answers are saved on this phone and will upload when you are back online.', icon: Ph.warning),
                    ],
                    if (_submitError != null) ...[
                      const SizedBox(height: 14),
                      InlineNotice(_submitError!, tone: Tone.danger, icon: Ph.warning),
                    ],
                    const SizedBox(height: 26),
                    MathText(q.text, style: questionStyle),
                    if (q.imageUrl != null) ...[
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(rSmall),
                        child: Image.network(q.imageUrl!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                      ),
                    ],
                    const SizedBox(height: 22),
                    for (final (i, o) in q.options.indexed) ...[
                      if (i > 0) const SizedBox(height: gapRow),
                      _OptionRow(letter: 'ABCD'[i], text: o, selected: q.chosen == i, onTap: () => _choose(i)),
                    ],
                    if (q.chosen != null)
                      Align(alignment: Alignment.centerRight, child: TextAction('Clear my answer', onTap: _clear)),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 10, gutter, 10),
              child: Row(children: [
                CircleBtn(icon: Ph.arrowLeft, size: 52, label: 'Previous question', onTap: _i > 0 ? () => _go(_i - 1) : null, tint: _i > 0 ? null : faint),
                const SizedBox(width: 10),
                CircleBtn(
                  icon: Ph.flag,
                  size: 52,
                  label: q.flagged ? 'Remove flag' : 'Flag for review',
                  ground: q.flagged ? warningSoft : null,
                  tint: q.flagged ? warning : null,
                  onTap: _toggleFlag,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    _submitting ? 'Submitting' : (isLast ? 'Review and submit' : 'Next question'),
                    icon: _submitting ? null : Ph.arrowRight,
                    onTap: _submitting ? null : (isLast ? _openMap : () => _go(_i + 1)),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({required this.letter, required this.text, required this.selected, required this.onTap});
  final String letter;
  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        label: 'Option $letter: ${plainMath(text)}${selected ? ', chosen' : ''}',
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.fromLTRB(17, 13, 17, 13),
          decoration: BoxDecoration(
            color: card,
            borderRadius: BorderRadius.circular(rCard),
            border: isDark ? Border.all(color: selected ? faint : hairline) : null,
            boxShadow: selected ? e2 : e1,
          ),
          child: Row(children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? actionFill : null,
                border: selected ? null : Border.all(color: ringIdle, width: 1.8),
              ),
              child: Text(letter, style: tagStyle.copyWith(fontSize: 12, color: selected ? actionInk : muted)),
            ),
            const SizedBox(width: 14),
            Expanded(child: MathText(text, style: optionStyle, display: true)),
          ]),
        ),
      );
}

class _MapChip extends StatelessWidget {
  const _MapChip({required this.n, required this.current, required this.answered, required this.flagged});
  final int n;
  final bool current;
  final bool answered;
  final bool flagged;

  @override
  Widget build(BuildContext context) {
    final Decoration deco;
    final Color fg;
    if (current) {
      deco = BoxDecoration(color: actionFill, borderRadius: BorderRadius.circular(rPill), boxShadow: e2);
      fg = actionInk;
    } else if (flagged) {
      deco = BoxDecoration(color: warningSoft, borderRadius: BorderRadius.circular(rPill));
      fg = warning;
    } else {
      deco = surface(radius: rPill, shadow: e1);
      fg = answered ? ink : faint;
    }
    return Container(
      width: 46,
      height: 34,
      alignment: Alignment.center,
      decoration: deco,
      child: Text(n.toString().padLeft(2, '0'), style: numStyle(size: 12.5, weight: FontWeight.w600, color: fg)),
    );
  }
}

enum _LegendKind { answered, flagged, open }

class _Legend extends StatelessWidget {
  const _Legend({required this.kind, required this.label});
  final _LegendKind kind;
  final String label;

  @override
  Widget build(BuildContext context) {
    // A small version of the real chip, so the legend matches what it explains.
    final (Decoration deco, Color fg) = switch (kind) {
      _LegendKind.answered => (surface(radius: rPill, shadow: e1), ink),
      _LegendKind.flagged => (BoxDecoration(color: warningSoft, borderRadius: BorderRadius.circular(rPill)), warning),
      _LegendKind.open => (surface(radius: rPill, shadow: e1), faint),
    };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 24, height: 16, decoration: deco, alignment: Alignment.center, child: Container(width: 8, height: 2, color: fg)),
      const SizedBox(width: 6),
      Text(label, style: labelStyle),
    ]);
  }
}
