import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// What a screen shows, so a change elsewhere in the app can tell it to load again.
enum Area { tests, students, questions, papers, settings, student }

/// The areas a successful write to [path] changes.
Set<Area> areasOf(String path) {
  final p = path.split('?').first;
  if (p.startsWith('/student')) return {Area.student};
  if (p.startsWith('/teacher/tests') || p.startsWith('/teacher/attempts')) return {Area.tests};
  if (p.startsWith('/teacher/students')) return {Area.students};
  if (p.startsWith('/teacher/questions') || p.startsWith('/teacher/uploads')) return {Area.questions};
  // Saving a paper puts its questions in the bank.
  if (p.startsWith('/teacher/papers') || p.startsWith('/teacher/drafts')) return {Area.papers, if (p.endsWith('/save')) Area.questions};
  if (p.startsWith('/teacher/subjects') || p.startsWith('/teacher/chapters') || p.startsWith('/teacher/settings')) {
    return {Area.settings, Area.questions, Area.students};
  }
  // Groups, the join code and join requests change what Home, Groups and Settings show.
  if (p.startsWith('/teacher/groups') || p.startsWith('/teacher/tuition') || p.startsWith('/teacher/join-requests')) {
    return {Area.settings, Area.students, Area.tests};
  }
  return const {};
}

/// Change notices between screens. The API client reports every successful write here.
class Changes extends ChangeNotifier {
  Set<Area> _last = const {};

  /// The areas the latest change touched.
  Set<Area> get last => _last;

  void report(String path) => reportAreas(areasOf(path));

  /// Also for news from outside the app, such as a notification arriving while it is open.
  void reportAreas(Set<Area> a) {
    if (a.isEmpty) return;
    _last = a;
    notifyListeners();
  }

  /// When someone last touched the screen. Polling stops after a long quiet spell, so a phone
  /// left open on a list does not keep the database awake.
  DateTime lastTouch = DateTime.now();
}

final changes = Changes();

/// How long without a touch before polling stops.
const _idle = Duration(minutes: 15);

/// Keeps a screen's data current without a manual refresh: it loads again (quietly) when a change
/// elsewhere touches its [refreshAreas], when the app comes back to the front, when the screen is
/// shown again after being covered or swapped out for another tab, and every [pollEvery] while it
/// is on screen and the phone is in use.
mixin AutoRefresh<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  /// What this screen shows.
  Set<Area> get refreshAreas;

  /// Loads the screen's data again without clearing what is shown.
  Future<void> refreshQuietly();

  /// For screens other people change (students writing tests): how often to check while shown.
  Duration? get pollEvery => null;

  /// A screen shown again within this long of its last load keeps what it has.
  Duration get staleAfter => const Duration(seconds: 20);

  DateTime _loaded = DateTime.now();
  Timer? _poll;
  Timer? _soon;
  ValueListenable<TickerModeData>? _shown;

  bool get _onScreen => _shown?.value.enabled ?? true;

  /// Call after every load, so a quick tab switch does not load again.
  void markLoaded() => _loaded = DateTime.now();

  void _refresh() {
    if (!mounted) return;
    markLoaded();
    refreshQuietly();
  }

  void _onChange() {
    if (!changes.last.any(refreshAreas.contains)) return;
    // A burst of writes (marking several answers) loads once.
    _soon?.cancel();
    _soon = Timer(const Duration(milliseconds: 500), _refresh);
  }

  void _onShown() {
    if (_onScreen && DateTime.now().difference(_loaded) > staleAfter) _refresh();
    _schedule();
  }

  void _schedule() {
    _poll?.cancel();
    final every = pollEvery;
    if (every == null || !_onScreen) return;
    _poll = Timer.periodic(every, (_) {
      if (_onScreen && DateTime.now().difference(changes.lastTouch) < _idle) _refresh();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    changes.addListener(_onChange);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // False while another tab is in front or a pushed screen covers this one.
    final shown = TickerMode.getValuesNotifier(context);
    if (!identical(shown, _shown)) {
      _shown?.removeListener(_onShown);
      _shown = shown..addListener(_onShown);
      _schedule();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      changes.lastTouch = DateTime.now();
      if (_onScreen && DateTime.now().difference(_loaded) > staleAfter) _refresh();
      _schedule();
    } else if (state == AppLifecycleState.paused) {
      _poll?.cancel();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _soon?.cancel();
    _shown?.removeListener(_onShown);
    changes.removeListener(_onChange);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
