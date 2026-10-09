import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// When someone last touched the screen. Polling stops after a long quiet spell, so a phone left
/// open on a tab does not keep the database awake. The app reports touches from its root.
DateTime lastTouch = DateTime.now();

/// How long without a touch before polling stops.
const _idle = Duration(minutes: 15);

/// Keeps a tab's numbers current without a refresh button: it loads again (quietly) when the app
/// comes back to the front, when the tab is shown again after another tab or a pushed screen covered
/// it, and every [pollEvery] while it is on screen and the phone is in use. Pulling down still works.
mixin AutoRefresh<T extends StatefulWidget> on State<T>, WidgetsBindingObserver {
  /// Loads the screen's data again without clearing what is shown.
  Future<void> refreshQuietly();

  /// How often to check while the screen is shown; null for a screen that only loads when shown.
  Duration? get pollEvery => null;

  /// A screen shown again within this long of its last load keeps what it has.
  Duration get staleAfter => const Duration(seconds: 30);

  DateTime _loaded = DateTime.now();
  Timer? _poll;
  ValueListenable<TickerModeData>? _shown;

  bool get _onScreen => _shown?.value.enabled ?? true;

  /// Call after every load, so a quick tab switch does not load again.
  void markLoaded() => _loaded = DateTime.now();

  void _refresh() {
    if (!mounted) return;
    markLoaded();
    refreshQuietly();
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
      if (_onScreen && DateTime.now().difference(lastTouch) < _idle) _refresh();
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      lastTouch = DateTime.now();
      if (_onScreen && DateTime.now().difference(_loaded) > staleAfter) _refresh();
      _schedule();
    } else if (state == AppLifecycleState.paused) {
      _poll?.cancel();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _shown?.removeListener(_onShown);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
