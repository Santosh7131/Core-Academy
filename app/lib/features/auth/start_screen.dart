import 'package:flutter/material.dart';

import '../../core/brand.dart';
import '../../core/session.dart';
import '../../theme.dart';
import '../../ui/brand_mark.dart';
import '../../ui/kit.dart';

/// The opening: the app's mark draws itself, then its name rises under it. It plays while the saved
/// login is restored (the router leaves for the next screen once both are done), and not again until
/// the app is next started. A phone set to fewer animations goes straight on.
class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1750)); // motion: approved
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (reduceMotion(context) || session.splashDone) {
      _c.value = 1;
      WidgetsBinding.instance.addPostFrameCallback((_) => session.finishSplash());
    } else {
      _c.forward().whenComplete(session.finishSplash); // motion: approved
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _span(double from, double to, [Curve curve = Curves.easeOutCubic]) =>
      curve.transform(((_c.value - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) {
              final arc = _span(0.0, 0.5, Curves.easeInOutCubic);
              final dot = _span(0.3, 0.6, Curves.easeOutBack);
              final name = _span(0.5, 0.82);
              // A slow connection keeps the start screen up after the animation: dots show it is still working.
              final waiting = _c.isCompleted && !session.restored;
              return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  BrandMark(size: 150, arc: arc, dot: dot),
                  const SizedBox(height: 14),
                  Opacity(
                    opacity: name,
                    child: Transform.translate(offset: Offset(0, (1 - name) * 14), child: Text(appName, style: titleStyle)),
                  ),
                  const SizedBox(height: 22),
                  SizedBox(height: 10, child: waiting ? LoadingDots(color: faint, size: 4.5) : null),
                ]),
              );
            },
          ),
        ),
      );
}
