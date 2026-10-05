import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'kit.dart';
import 'tokens.dart';

/// The ring an answer option's letter (or tick) sits in. Choosing it fills the ring, the mark
/// settles in from 80% with a slight overshoot, and the phone gives one light tick.
class OptionMark extends StatelessWidget {
  const OptionMark({super.key, required this.selected, this.letter, this.size = 28, this.color, this.onColor});

  final bool selected;

  /// The option's letter; without one, a tick shows when selected.
  final String? letter;
  final double size;

  /// The filled ring's colour and the mark's colour on it.
  final Color? color;
  final Color? onColor;

  @override
  Widget build(BuildContext context) {
    final fill = color ?? actionFill;
    final fg = onColor ?? actionInk;
    final mark = letter == null
        ? Icon(Ph.check, size: size * 0.6, color: selected ? fg : Colors.transparent)
        : Text(letter!, style: tagStyle.copyWith(fontSize: size * 0.43, color: selected ? fg : muted));
    // A new key per state restarts the settle, so it plays each time the option is chosen.
    return TweenAnimationBuilder<double>( // motion: approved
      key: ValueKey(selected),
      tween: Tween(begin: selected ? 0.8 : 1, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutBack,
      builder: (context, scale, child) => Transform.scale(scale: scale, child: child),
      child: AnimatedContainer( // motion: approved
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? fill : fill.withValues(alpha: 0),
          border: Border.all(color: selected ? fill : ringIdle, width: 1.8),
        ),
        child: mark,
      ),
    );
  }
}

/// The light tick that goes with choosing an option.
void optionTick() => HapticFeedback.selectionClick();
