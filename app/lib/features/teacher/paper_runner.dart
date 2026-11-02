import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api.dart';
import '../../core/pool.dart';

/// A minute and a half a question, rounded up to a limit the test editor offers.
int suggestedLimit(int questions) => const [20, 30, 45, 60, 90, 120, 180].firstWhere((m) => m >= (questions * 1.5).ceil(), orElse: () => 180);

/// What the server holds for one paper, counted the way the paper's own screen counts it: how far AI has read, what is ready and
/// what still needs the tutor.
class PaperFacts {
  const PaperFacts(this.paper, this.pages, this.drafts, [this.tests = const []]);
  static const empty = PaperFacts({}, [], []);

  final Map<String, dynamic> paper;
  final List<Map<String, dynamic>> pages;
  final List<Map<String, dynamic>> drafts;

  /// The tests made from this paper, newest first.
  final List<Map<String, dynamic>> tests;

  bool get loaded => paper.isNotEmpty;

  /// A test made from this paper has been posted: it is with the students, now or on its day.
  bool get posted => tests.any((t) => t['status'] == 'published');

  /// The questions AI found, without the ones the tutor skipped.
  List<Map<String, dynamic>> get live => drafts.where((d) => d['status'] != 'discarded').toList();

  /// Multiple-choice questions still to be saved (the ones a test is made of).
  List<Map<String, dynamic>> get questions => live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq').toList();

  /// A question with its answer marked, and its picture if it needs one.
  static bool isReady(Map<String, dynamic> d) =>
      d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] != null && (d['needs_diagram'] != true || d['image_key'] != null);

  int get ready => live.where(isReady).length;

  /// Questions already saved from this paper into the question bank.
  int get saved => live.where((d) => d['status'] == 'saved').length;

  /// Every multiple-choice question of the paper, whatever has happened to it since.
  int get mcq => live.where((d) => d['kind'] == 'mcq').length;

  /// Questions that need the tutor: no answer yet, or a picture to add.
  int get toCheck => live.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && !isReady(d)).length;

  /// Questions with an answer, found by AI, a printed key or the tutor.
  int get answered => questions.where((d) => d['correct_option'] != null).length;

  int get pageCount => pages.length;
  int get pagesRead => pages.where((p) => p['ai_status'] == 'done').length;

  /// Pages AI has not read, once they have all arrived.
  bool get unread => pages.any((p) => p['ai_status'] != 'done' && p['uploaded'] != false);

  /// Questions AI has not looked for an answer to, or could not check last time because the models were down.
  bool get unanswered => drafts.any((d) =>
      d['status'] == 'draft' &&
      d['kind'] == 'mcq' &&
      d['correct_option'] == null &&
      d['needs_diagram'] != true &&
      (d['answer_checked'] != true || d['ai_note'] == 'unchecked'));

  /// Questions the first two checks could not settle, which a stronger model is asked about next.
  int get secondPending => drafts.where((d) => d['status'] == 'draft' && d['kind'] == 'mcq' && d['correct_option'] == null && d['ai_votes'] != null).length;

  /// Something is left for AI to do.
  bool get workLeft => unread || unanswered || secondPending > 0;

  /// Nothing needs the tutor and there is something to post: questions that are ready, or saved already and not in a test yet.
  bool get postable => loaded && !workLeft && toCheck == 0 && (ready > 0 || saved > 0);
}

/// Reads one paper with AI, step by step, without a screen of its own: its details, every page, the answers, then a second opinion on
/// the answers the first two checks could not settle. It does what the paper's own screen does when it opens a paper to read, so a
/// paper read here can be opened there afterwards. [onChange] is called whenever something to show has changed.
class PaperRunner {
  PaperRunner(this.id, {this.onChange});

  final String id;
  final VoidCallback? onChange;

  PaperFacts facts = PaperFacts.empty;

  /// Why AI stopped short, in plain words; null when nothing went wrong.
  String? problem;

  /// When AI said it had used its limit: the time the calls waiting for it carry on.
  DateTime? busyUntil;

  bool get running => _running;
  bool _running = false;
  bool _stopped = false;

  /// How many pages are read at once, how many batches of questions are answered at once, how many second opinions are asked at once
  /// (the limits are the paper screen's: Gemini's free plan takes 15 page reads a minute, the stronger models are slow and small).
  static const _readWidth = 4;
  static const _answerWidth = 3;
  static const _secondWidth = 2;

  void _changed() => onChange?.call();

  /// Stops any work in progress: calls on their way finish, no new ones start.
  void stop() => _stopped = true;

  Future<void> load() async {
    final d = await api.get('/teacher/papers/$id');
    facts = PaperFacts(
      Map<String, dynamic>.from(d['paper']),
      (d['pages'] as List).cast<Map<String, dynamic>>(),
      (d['drafts'] as List).cast<Map<String, dynamic>>(),
      ((d['tests'] as List?) ?? const []).cast<Map<String, dynamic>>(),
    );
    _changed();
  }

  bool _loading = false;
  bool _loadAgain = false;

  /// Loads the paper again soon, one load at a time: calls that arrive during a load share the next one.
  Future<void> _reloadSoon() async {
    if (_loading) {
      _loadAgain = true;
      return;
    }
    _loading = true;
    try {
      do {
        _loadAgain = false;
        try {
          await load();
        } on ApiException {
          return;
        }
      } while (_loadAgain && !_stopped);
    } finally {
      _loading = false;
    }
  }

  /// Calls AI through the server, waiting out its per-minute limit. Throws when AI fails another way or stays busy too long.
  Future<dynamic> _ai(Future<dynamic> Function() call) async {
    for (var waits = 0;; waits++) {
      try {
        return await call();
      } on ApiException catch (e) {
        if (e.code != 'ai_busy' || waits >= 10 || _stopped) rethrow;
        final secs = (int.tryParse(RegExp(r'(\d+) second').firstMatch(e.message)?.group(1) ?? '') ?? 20).clamp(4, 60);
        final until = DateTime.now().add(Duration(seconds: secs));
        if (busyUntil == null || until.isAfter(busyUntil!)) busyUntil = until;
        while (!_stopped && DateTime.now().isBefore(until)) {
          _changed();
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      }
    }
  }

  /// The whole run, from what the server holds now. Safe to call again: it carries on from where the paper is.
  Future<void> run() async {
    if (_running) return;
    _running = true;
    _stopped = false;
    problem = null;
    busyUntil = null;
    _changed();
    try {
      await load();
      // The paper's details are asked for alongside the reading and never waited for.
      final named = facts.paper['ai_details'] == null
          ? _ai(() => api.post('/teacher/papers/$id/detect', null, const Duration(minutes: 2))).then<void>((_) {}, onError: (_) {})
          : Future<void>.value();
      await _readAndAnswer();
      await named;
      if (_stopped) return;
      await load();
      await _secondOpinions();
    } on ApiException catch (e) {
      problem = e.message;
    } finally {
      _running = false;
      busyUntil = null;
      _changed();
    }
  }

  /// Reads the pages that are not done yet, [_readWidth] at a time, and looks for answers to the questions already read while the
  /// other pages are still being read. A printed answer key on a late page replaces whatever AI worked out for those questions in the
  /// meantime (the server does that), so the key still wins.
  Future<void> _readAndAnswer() async {
    final todo = [for (final p in facts.pages) if (p['ai_status'] != 'done') p['page_no'] as int];
    var reading = todo.isNotEmpty;
    final firstRead = Completer<void>();
    // One page that cannot be read does not stop the others. A page that fails is tried once more after a short pause, since a busy
    // model or a bad moment on the line is usually over by then.
    late final Map<int, Object> unread;
    final readAll = forEachSettled(todo, _readWidth, (n) async {
      for (var attempt = 0;; attempt++) {
        try {
          await _ai(() => api.post('/teacher/papers/$id/pages/$n/read', null, const Duration(minutes: 3)));
          break;
        } on ApiException {
          if (attempt >= 1 || _stopped) rethrow;
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      }
      _reloadSoon();
      if (!firstRead.isCompleted) firstRead.complete();
    }).then<void>((failed) => unread = failed).whenComplete(() {
      reading = false;
      if (!firstRead.isCompleted) firstRead.complete();
    });

    // Answers start once the first page is read. Each worker keeps asking while pages are still coming; the server hands every call
    // its own batch, so no question is worked out twice.
    var failed = false;
    String? answerError;
    Future<void> worker() async {
      await firstRead.future;
      var hiccups = 0;
      while (!_stopped && !failed) {
        final pagesPending = reading; // was a page still being read when this call went out?
        final dynamic r;
        try {
          r = await _ai(() => api.post('/teacher/papers/$id/answers', null, const Duration(minutes: 2)));
        } on ApiException catch (e) {
          // A slow reply, a server blip or a dropped connection: wait a moment and ask again before giving up.
          if ((e.status == 0 || e.status >= 500) && ++hiccups <= 3) {
            await Future<void>.delayed(Duration(seconds: 3 * hiccups));
            continue;
          }
          failed = true;
          answerError = e.message;
          return;
        }
        final tried = r['tried'] as int;
        final fromKey = r['from_key'] as int;
        if (tried > 0 || fromKey > 0) _reloadSoon();
        if (tried == 0) {
          if (!pagesPending) return; // nothing open, and every page was read before this call
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    }

    await Future.wait([for (var i = 0; i < _answerWidth; i++) worker()]);
    await readAll;
    await load();
    final why = unread.values.whereType<ApiException>().map((e) => e.message).firstOrNull ?? 'Try again in a moment.';
    problem = answerError ??
        (unread.isEmpty
            ? null
            : unread.length == 1
                ? 'Page ${unread.keys.first} could not be read. $why'
                : '${unread.length} pages could not be read. $why');
    _changed();
  }

  /// Asks a stronger AI model about the questions the first two checks could not settle. It is slow and often busy, so it never shows
  /// an error: whatever it cannot settle stays with the tutor (the server gives up on a question after two tries).
  Future<void> _secondOpinions() async {
    if (_stopped || facts.secondPending == 0) return;
    var stuck = false;
    Future<void> worker() async {
      while (!_stopped && !stuck) {
        final dynamic r;
        try {
          r = await api.post('/teacher/papers/$id/second-opinion', null, const Duration(minutes: 2));
        } on ApiException {
          stuck = true;
          return;
        }
        if ((r['tried'] as int) == 0) return;
        _reloadSoon();
        // Nobody could be asked, so the strong models are busy: a pause before the next try helps.
        if ((r['asked'] ?? 1) == 0) await Future<void>.delayed(const Duration(seconds: 8));
      }
    }

    await Future.wait([for (var i = 0; i < _secondWidth; i++) worker()]);
    await load();
  }
}
