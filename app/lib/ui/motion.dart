import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

// The app's motion, in one place. Santosh asked for animation on opening the app and for loading
// animations (2026-10-10), on top of the short fades and the press scale he approved on 2026-10-05.
// Every movement here is short, eased and skipped when the phone asks for fewer animations.
// Lines that start a movement carry "// motion: approved" for tools/audit.py.

/// The phone's "remove animations" setting: everything here then shows its end state at once.
bool reduceMotion(BuildContext context) => MediaQuery.maybeDisableAnimationsOf(context) ?? false;

const _ease = Curves.easeOutCubic;

// ---------------------------------------------------------------- reveal

/// Fades its child in and lifts it a few pixels when it first appears, after [delay]. Give [scope]
/// (a State or any object that lives as long as the screen) and an [id] and it plays once per
/// screen: a row scrolled away and back does not play again.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 460),
    this.dy = 16,
    this.scope,
    this.id,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  /// How far below its place the child starts, in pixels.
  final double dy;
  final Object? scope;
  final Object? id;

  static final _seen = Expando<Set<Object>>('Reveal.seen');

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration); // motion: approved
  bool _skip = false;

  @override
  void initState() {
    super.initState();
    final scope = widget.scope;
    final id = widget.id;
    if (scope != null && id != null) {
      final seen = Reveal._seen[scope] ??= <Object>{};
      if (!seen.add(id)) _skip = true;
    }
    if (_skip) {
      _c.value = 1;
    } else if (widget.delay == Duration.zero) {
      _c.forward(); // motion: approved
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _c.forward(); // motion: approved
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return widget.child;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        final t = _ease.transform(_c.value);
        return Opacity(opacity: t, child: Transform.translate(offset: Offset(0, (1 - t) * widget.dy), child: child));
      },
    );
  }
}

/// [Reveal] for a list: each child comes in a little after the one before it, up to [max] of them.
List<Widget> staggered(List<Widget> children, {Object? scope, String prefix = 'row', int max = 9, int stepMs = 55, int startMs = 0}) => [
      for (final (i, c) in children.indexed)
        i >= max ? c : Reveal(scope: scope, id: '$prefix$i', delay: Duration(milliseconds: startMs + i * stepMs), child: c),
    ];

// ---------------------------------------------------------------- loading

/// One light sweep shared by every [SkeletonBox] under it.
class SkeletonScope extends StatefulWidget {
  const SkeletonScope({super.key, required this.child});
  final Widget child;

  static Animation<double>? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SweepShare>()?.sweep;

  @override
  State<SkeletonScope> createState() => _SkeletonScopeState();
}

class _SkeletonScopeState extends State<SkeletonScope> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500)); // motion: approved

  @override
  void initState() {
    super.initState();
    _c.repeat(); // motion: approved
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SweepShare(sweep: _c, child: widget.child);
}

class _SweepShare extends InheritedWidget {
  const _SweepShare({required this.sweep, required super.child});
  final Animation<double> sweep;

  @override
  bool updateShouldNotify(_SweepShare old) => sweep != old.sweep;
}

/// A grey placeholder in the shape of what is loading, with a soft light moving across it.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({super.key, this.width, this.height = 14, this.radius = 8});
  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final sweep = SkeletonScope.of(context);
    final still = reduceMotion(context) || sweep == null;
    final base = isDark ? const Color(0xFF1E1E24) : const Color(0xFFEDEDF1);
    final glow = isDark ? const Color(0xFF2A2A32) : const Color(0xFFF8F8FA);
    return SizedBox(
      width: width,
      height: height,
      child: still
          ? DecoratedBox(decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(radius)))
          : AnimatedBuilder(
              animation: sweep,
              builder: (context, _) {
                final x = -1.2 + 3.4 * sweep.value;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(radius),
                    gradient: LinearGradient( // motion: approved
                      begin: Alignment(x - 0.8, 0),
                      end: Alignment(x + 0.8, 0),
                      colors: [base, glow, base],
                      stops: const [0.15, 0.5, 0.85],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// What a list of rows looks like while it loads.
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({super.key, this.count = 4, this.padding = const EdgeInsets.symmetric(horizontal: gutter, vertical: 8)});
  final int count;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final rows = Padding(
      padding: padding,
      child: Column(children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(height: gapRow),
          Container(
            height: 70,
            padding: const EdgeInsets.fromLTRB(17, 15, 17, 15),
            decoration: surface(radius: rCard, shadow: e1),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              SkeletonBox(width: 130.0 + (i % 3) * 36, height: 13),
              const SizedBox(height: 9),
              SkeletonBox(width: 190.0 - (i % 2) * 40, height: 10),
            ]),
          ),
        ],
      ]),
    );
    // Inside another skeleton the rows share its sweep; alone they bring their own.
    return SkeletonScope.of(context) == null ? SkeletonScope(child: rows) : rows;
  }
}

/// A big card with a few lines, for a screen's hero while it loads.
class SkeletonHero extends StatelessWidget {
  const SkeletonHero({super.key, this.height = 200});
  final double height;

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        padding: const EdgeInsets.all(20),
        decoration: surface(radius: rHero, shadow: e3),
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SkeletonBox(width: 70, height: 10),
          SizedBox(height: 18),
          SkeletonBox(width: 190, height: 24, radius: 10),
          SizedBox(height: 12),
          SkeletonBox(width: 150, height: 11),
          Spacer(),
          SkeletonBox(height: 52, radius: rSmall),
        ]),
      );
}

/// Three dots that rise and fall in turn: the loading sign inside a button.
class LoadingDots extends StatefulWidget {
  const LoadingDots({super.key, this.color, this.size = 5});
  final Color? color;
  final double size;

  @override
  State<LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<LoadingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900)); // motion: approved

  @override
  void initState() {
    super.initState();
    _c.repeat(); // motion: approved
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? muted;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) SizedBox(width: widget.size * 0.9),
          Transform.translate(
            offset: Offset(0, -widget.size * 0.9 * math.max(0, math.sin((_c.value * 2 - i * 0.28) * math.pi))),
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ],
      ]),
    );
  }
}

// ---------------------------------------------------------------- figures

/// A figure that counts up to its value when it first shows, then follows it when it changes.
class CountUp extends StatelessWidget {
  const CountUp({super.key, required this.value, required this.builder, this.duration = const Duration(milliseconds: 900)});
  final double value;
  final Widget Function(BuildContext context, double current) builder;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return builder(context, value);
    return TweenAnimationBuilder<double>( // motion: approved
      tween: Tween(begin: 0, end: value),
      duration: duration,
      curve: Curves.easeOutQuart,
      builder: (context, v, _) => builder(context, v),
    );
  }
}

/// A soft breathing of opacity, for something that is working (the AI reader's ring).
class Breathe extends StatefulWidget {
  const Breathe({super.key, required this.child});
  final Widget child;

  @override
  State<Breathe> createState() => _BreatheState();
}

class _BreatheState extends State<Breathe> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400)); // motion: approved

  @override
  void initState() {
    super.initState();
    _c.repeat(reverse: true); // motion: approved
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (reduceMotion(context)) return widget.child;
    return FadeTransition(opacity: Tween(begin: 0.45, end: 1.0).animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut)), child: widget.child);
  }
}
