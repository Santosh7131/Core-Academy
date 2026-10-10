// Copied from app/lib/ui/kit.dart by tools/sync-admin-ui.mjs. Edit the original, not this copy.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'icons.dart';
import 'motion.dart';
import 'tokens.dart';

export 'icons.dart';
export 'motion.dart';

// The component vocabulary from the guide's section 5, as widgets.
// Motion stays subtle: a 130 ms press scale and a short fade for centred cards.

TextStyle get buttonStyle => rowTitleStyle.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.44);
TextStyle get chipStyle => labelStyle.copyWith(fontSize: 12.5, letterSpacing: -0.31, color: body);
TextStyle get tagStyle => labelStyle.copyWith(fontSize: 10.5, fontWeight: FontWeight.w700, letterSpacing: 0);
TextStyle get cardTitleStyle => titleStyle.copyWith(fontSize: 23, letterSpacing: -0.97);
TextStyle get emptyTitleStyle => titleStyle.copyWith(fontSize: 21, letterSpacing: -0.88);

/// Prose with every figure set in mono tabular (rule 4).
class Fig extends StatelessWidget {
  const Fig(this.text, {super.key, required this.style, this.numColor, this.maxLines, this.textAlign});

  final String text;
  final TextStyle style;
  final Color? numColor;
  final int? maxLines;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var last = 0;
    final fig = numStyle(
      size: style.fontSize ?? 14,
      weight: style.fontWeight ?? FontWeight.w600,
      color: numColor ?? style.color,
    ).copyWith(height: style.height);
    for (final m in figurePattern.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      spans.add(TextSpan(text: m.group(0), style: fig));
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      textAlign: textAlign,
    );
  }
}

/// Uppercase small-caps kicker; figures inside it stay mono.
class Kicker extends StatelessWidget {
  const Kicker(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Fig(text.toUpperCase(), style: kickerStyle.copyWith(color: color ?? faint), maxLines: 1);
}

/// Replaces the ink splash: the child scales to 0.978 while pressed (guide: 130 ms, easeOutCubic).
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.label, this.enabled = true});

  final Widget child;
  final VoidCallback? onTap;
  final String? label;
  final bool enabled;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onTap != null;
    // Its own accessibility node, so a button inside a header is reachable on its own;
    // with a label, the label replaces the child's text instead of repeating it.
    return Semantics(
      container: true,
      button: true,
      enabled: active,
      label: widget.label,
      excludeSemantics: widget.label != null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: active ? (_) => _set(true) : null,
        onTapUp: active ? (_) => _set(false) : null,
        onTapCancel: active ? () => _set(false) : null,
        onTap: active ? widget.onTap : null,
        child: AnimatedScale(
          scale: _down ? 0.978 : 1,
          duration: const Duration(milliseconds: 130),
          curve: Curves.easeOutCubic,
          child: widget.child,
        ),
      ),
    );
  }
}

/// The floating surface: the atom almost everything is built from.
class Surface extends StatelessWidget {
  const Surface({super.key, required this.child, this.padding = EdgeInsets.zero, this.radius = rCard, this.shadow, this.color});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final List<BoxShadow>? shadow;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        decoration: surface(radius: radius, color: color, shadow: shadow ?? e2),
        padding: padding,
        child: child,
      );
}

class CircleBtn extends StatelessWidget {
  const CircleBtn({super.key, required this.icon, this.onTap, this.size = 40, this.filled = false, this.tint, this.ground, this.label});

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final bool filled;
  final Color? tint;
  final Color? ground;
  final String? label;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        label: label,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: filled
              ? BoxDecoration(color: actionFill, shape: BoxShape.circle, boxShadow: e2)
              : ground != null
                  ? BoxDecoration(color: ground, shape: BoxShape.circle)
                  : surface(radius: rPill, shadow: e1),
          child: Icon(icon, size: size * 0.47, color: filled ? actionInk : (tint ?? ink)),
        ),
      );
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton(this.label, {super.key, this.onTap, this.icon, this.leadingIcon, this.disabledReason, this.busy = false});

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;

  /// An icon before the label, for a button named after a thing (a test) rather than a step.
  final IconData? leadingIcon;

  /// Shown under a disabled button; the guide never disables silently.
  final String? disabledReason;

  /// Working on it: three moving dots follow the label and the button does not take taps.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final fg = enabled || busy ? actionInk : faint;
    final button = Pressable(
      onTap: onTap,
      label: label,
      enabled: enabled,
      child: AnimatedContainer( // motion: approved
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
          color: enabled || busy ? actionFill : fill,
          borderRadius: BorderRadius.circular(rSmall),
          boxShadow: enabled ? e4 : const [],
        ),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (leadingIcon != null && !busy) ...[Icon(leadingIcon, size: 19, color: fg), const SizedBox(width: 9)],
          Flexible(child: Fig(label, style: buttonStyle.copyWith(color: fg), maxLines: 1)),
          if (busy) ...[const SizedBox(width: 10), LoadingDots(color: fg, size: 4.5)]
          else if (icon != null) ...[const SizedBox(width: 8), Icon(icon, size: 18, color: fg)],
        ]),
      ),
    );
    if (enabled || disabledReason == null) return button;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      button,
      const SizedBox(height: 9),
      Fig(disabledReason!, style: labelStyle, textAlign: TextAlign.center),
    ]);
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton(this.label, {super.key, this.onTap, this.icon, this.tint});

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final fg = onTap == null ? faint : (tint ?? ink);
    return Pressable(
      onTap: onTap,
      label: label,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: surface(radius: rSmall, shadow: e1),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 8)],
          Flexible(child: Fig(label, style: buttonStyle.copyWith(color: fg), maxLines: 1)),
        ]),
      ),
    );
  }
}

/// Small text action with no surface of its own.
class TextAction extends StatelessWidget {
  const TextAction(this.label, {super.key, this.onTap, this.color});
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        label: label,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Fig(label, style: chipStyle.copyWith(color: color ?? muted, fontWeight: FontWeight.w600)),
        ),
      );
}

/// Kicker, mono count, then a hairline to the edge. Alert turns it danger.
class SectionRule extends StatelessWidget {
  const SectionRule(this.label, {super.key, this.count, this.alert = false, this.trailing, this.padding = const EdgeInsets.fromLTRB(gutter, 22, gutter, 11)});

  final String label;
  final int? count;
  final bool alert;

  /// A small action at the end of the rule, such as "All results".
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final c = alert ? danger : faint;
    return Padding(
      padding: padding,
      child: Row(children: [
        Text(label.toUpperCase(), style: kickerStyle.copyWith(color: c)),
        if (count != null) ...[const SizedBox(width: 10), Text('$count', style: numStyle(size: 11, color: c))],
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: hairline)),
        if (trailing != null) ...[const SizedBox(width: 10), trailing!],
      ]),
    );
  }
}

class SegChip extends StatelessWidget {
  const SegChip(this.label, {super.key, required this.selected, this.onTap, this.count});

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? actionInk : body;
    return Pressable(
      onTap: onTap,
      label: label,
      // No `alignment`: an aligned Container grows to fill a Wrap or Column.
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: selected
            ? BoxDecoration(color: actionFill, borderRadius: BorderRadius.circular(rPill), boxShadow: e2)
            : surface(radius: rPill, shadow: e1),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: chipStyle.copyWith(color: fg)),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text('$count', style: numStyle(size: 12.5, color: fg.withValues(alpha: 0.75))),
          ],
        ]),
      ),
    );
  }
}

/// Two or three choices in one track, with a white thumb that slides under the chosen one.
class SegmentedToggle extends StatelessWidget {
  const SegmentedToggle({super.key, required this.labels, required this.index, required this.onChanged});
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final n = labels.length;
    return Container(
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rSmall + 2)),
      child: Stack(children: [
        AnimatedAlign( // motion: approved
          alignment: Alignment(n < 2 ? 0 : -1 + 2 * index / (n - 1), 0),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: FractionallySizedBox(
            widthFactor: 1 / n,
            heightFactor: 1,
            child: Container(decoration: surface(radius: rSmall, shadow: e1, color: isDark ? cardHi : card)),
          ),
        ),
        Row(children: [
          for (final (i, l) in labels.indexed)
            Expanded(
              child: Pressable(
                label: l,
                onTap: () => onChanged(i),
                child: Center(child: Text(l, style: chipStyle.copyWith(color: i == index ? ink : muted, fontWeight: FontWeight.w700))),
              ),
            ),
        ]),
      ]),
    );
  }
}

enum Tone { neutral, success, danger, warning, ai }

/// Labels carry no hue; only real state (or the AI reader) earns colour.
class TagChip extends StatelessWidget {
  const TagChip(this.text, {super.key, this.tone = Tone.neutral});
  final String text;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      Tone.neutral => (fill, muted),
      Tone.success => (successSoft, success),
      Tone.danger => (dangerSoft, danger),
      Tone.warning => (warningSoft, warning),
      Tone.ai => (aiAccentSoft, aiAccentInk),
    };
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(rPill)),
      // As wide as its text, and cut short with an ellipsis when its row has less room than that.
      child: Center(widthFactor: 1, child: Fig(text, style: tagStyle.copyWith(color: fg), maxLines: 1)),
    );
  }
}

/// Person colour at 12% (24% dark), initials in that colour. Never a solid fill.
class AppAvatar extends StatelessWidget {
  const AppAvatar({super.key, required this.name, required this.seed, this.size = 34});
  final String name;
  final String seed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = personColor(seed);
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    final initials = parts.take(2).map((p) => p[0].toUpperCase()).join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.withValues(alpha: isDark ? 0.24 : 0.12), shape: BoxShape.circle),
      child: Text(initials, style: tagStyle.copyWith(fontSize: size >= 34 ? 11.5 : 9.5, color: c, letterSpacing: -0.1)),
    );
  }
}

/// The row (guide section 5): 17 left / 15 right, e1, rCard.
class RowTile extends StatelessWidget {
  const RowTile({super.key, this.leading, this.title, this.titleWidget, this.meta, this.metaWidget, this.trailing, this.onTap, this.chevron = false, this.metaColor});

  final Widget? leading;
  final String? title;
  final Widget? titleWidget;
  final String? meta;
  final Widget? metaWidget;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool chevron;
  final Color? metaColor;

  @override
  Widget build(BuildContext context) => Pressable(
        // No label: a screen reader reads the row's own title, details and figures.
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(17, 15, 15, 15),
          decoration: surface(radius: rCard, shadow: e1),
          child: Row(children: [
            if (leading != null) ...[leading!, const SizedBox(width: 14)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                titleWidget ?? Fig(title ?? '', style: rowTitleStyle, maxLines: 2),
                if (metaWidget != null || meta != null) ...[
                  const SizedBox(height: 2),
                  metaWidget ?? Fig(meta!, style: labelStyle.copyWith(color: metaColor ?? muted), maxLines: 2),
                ],
              ]),
            ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
            if (chevron) ...[const SizedBox(width: 6), Icon(Ph.caretRight, size: 16, color: faint)],
          ]),
        ),
      );
}

/// The near-black bar from the measurement card (guide section 5 and 7).
Color get measureFill => ink;

/// A bar that fills to [fraction] when it first shows and follows it when it changes.
class Track extends StatelessWidget {
  const Track(this.fraction, {super.key, this.height = 7, this.color, this.trackColor});
  final double fraction;
  final double height;
  final Color? color;
  final Color? trackColor;

  @override
  Widget build(BuildContext context) {
    final target = fraction.clamp(0, 1).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(5),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          Positioned.fill(child: ColoredBox(color: trackColor ?? fill)),
          TweenAnimationBuilder<double>( // motion: approved
            tween: Tween(begin: reduceMotion(context) ? target : 0, end: target),
            duration: const Duration(milliseconds: 750),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => FractionallySizedBox(
              widthFactor: v,
              child: Container(decoration: BoxDecoration(color: color ?? measureFill, borderRadius: BorderRadius.circular(5))),
            ),
          ),
        ]),
      ),
    );
  }
}

/// One per screen, maximum.
class MeasurementCard extends StatelessWidget {
  const MeasurementCard({super.key, required this.label, required this.value, this.unit, this.fraction, this.note, this.valueColor, this.countTo});

  final String label;
  final String value;

  /// A whole number the figure counts up to when the card first shows (then [value] is not used).
  final int? countTo;
  final String? unit;
  final double? fraction;
  final String? note;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 17),
        decoration: surface(radius: rHero, shadow: e3),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: labelStyle),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            countTo == null
                ? Text(value, style: numStyle(size: 36, color: valueColor))
                : CountUp(value: countTo!.toDouble(), builder: (context, v) => Text('${v.round()}', style: numStyle(size: 36, color: valueColor))),
            if (unit != null) ...[const SizedBox(width: 4), Text(unit!, style: numStyle(size: 14, weight: FontWeight.w600, color: muted))],
          ]),
          if (fraction != null) ...[const SizedBox(height: 13), Track(fraction!)],
          if (note != null) ...[const SizedBox(height: 11), Fig(note!, style: bodyStyle.copyWith(color: muted), numColor: body)],
        ]),
      );
}

class StatSmall {
  const StatSmall(this.label, this.value);
  final String label;
  final String value;
}

/// Never a 2x2 of equals: one tall card with the figure that matters, two small beside it.
class StatGrid extends StatelessWidget {
  const StatGrid({super.key, required this.label, required this.value, this.note, this.alert = false, required this.small});

  final String label;
  final String value;
  final String? note;
  final bool alert;
  final List<StatSmall> small;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            flex: 132,
            child: Surface(
              padding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: labelStyle),
                const Spacer(),
                Text(value, style: numStyle(size: 46, color: alert ? danger : ink)),
                if (note != null) ...[const SizedBox(height: 8), Fig(note!, style: labelStyle, maxLines: 2)],
              ]),
            ),
          ),
          const SizedBox(width: gapRow),
          Expanded(
            flex: 100,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, s) in small.indexed) ...[
                if (i > 0) const SizedBox(height: gapRow),
                Expanded(
                  child: Surface(
                    padding: const EdgeInsets.fromLTRB(15, 13, 15, 13),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.label, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const Spacer(),
                      Text(s.value, style: numStyle(size: 26)),
                    ]),
                  ),
                ),
              ],
            ]),
          ),
        ]),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 76,
            height: 76,
            decoration: surface(radius: rPill, shadow: e2),
            child: Icon(icon, size: 30, color: faint),
          ),
          const SizedBox(height: 18),
          Text(title, style: emptyTitleStyle, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Fig(body, style: bodyStyle.copyWith(color: muted), textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ]),
      );
}

/// Visibly different from the empty state: a danger mark and a retry.
class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(color: dangerSoft, shape: BoxShape.circle),
            child: Icon(Ph.warning, size: 30, color: danger),
          ),
          const SizedBox(height: 18),
          Text('Could not load this', style: emptyTitleStyle, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Fig(message, style: bodyStyle.copyWith(color: muted), textAlign: TextAlign.center),
          const SizedBox(height: 18),
          SizedBox(width: 180, child: SecondaryButton('Try again', icon: Ph.arrowsClockwise, onTap: onRetry)),
        ]),
      );
}

/// What a screen shows while its list loads: grey rows in the shape of the real ones, with a soft
/// light moving across them. [inset] adds the side gutter for screens that do not have one.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.text = 'Loading', this.rows = 4, this.inset = false});
  final String text;
  final int rows;
  final bool inset;

  @override
  Widget build(BuildContext context) => Semantics(
        label: text,
        child: SkeletonRows(count: rows, padding: EdgeInsets.symmetric(horizontal: inset ? gutter : 0, vertical: 8)),
      );
}

/// Placeholder-only inputs grouped in one surface, split by hairlines. Focus lifts it.
class GroupedInputs extends StatefulWidget {
  const GroupedInputs({super.key, required this.children});
  final List<Widget> children;

  @override
  State<GroupedInputs> createState() => _GroupedInputsState();
}

class _GroupedInputsState extends State<GroupedInputs> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (f) => setState(() => _focused = f),
        child: Container(
          decoration: surface(radius: rCard, shadow: _focused ? e3 : e1),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (i, c) in widget.children.indexed) ...[
              if (i > 0) Padding(padding: const EdgeInsets.only(left: 17), child: Container(height: 1, color: hairline)),
              c,
            ],
          ]),
        ),
      );
}

class BareField extends StatelessWidget {
  const BareField({
    super.key,
    required this.controller,
    required this.placeholder,
    this.obscure = false,
    this.keyboard,
    this.action,
    this.onSubmitted,
    this.maxLines = 1,
    this.minLines,
    this.autofocus = false,
    this.focusNode,
    this.capitalization = TextCapitalization.none,
    this.onChanged,
    this.style,
    this.inputFormatters,
    this.autofillHints,
    this.suffix,
  });

  final TextEditingController controller;
  final String placeholder;
  final bool obscure;
  final TextInputType? keyboard;
  final TextInputAction? action;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final int? maxLines;
  final int? minLines;
  final bool autofocus;
  final FocusNode? focusNode;
  final TextCapitalization capitalization;
  final TextStyle? style;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;

  /// A small control at the end of the field, such as the show or hide eye of a password.
  final Widget? suffix;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        obscureText: obscure,
        keyboardType: keyboard,
        textInputAction: action,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        inputFormatters: inputFormatters,
        autofillHints: autofillHints,
        maxLines: obscure ? 1 : maxLines,
        minLines: minLines,
        autocorrect: false,
        enableSuggestions: !obscure && capitalization != TextCapitalization.none,
        textCapitalization: capitalization,
        cursorColor: ink,
        style: style ?? rowTitleStyle.copyWith(fontWeight: FontWeight.w500, fontSize: 15),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: placeholder,
          hintStyle: rowTitleStyle.copyWith(color: faint, fontWeight: FontWeight.w500, fontSize: 15),
          contentPadding: const EdgeInsets.fromLTRB(17, 16, 17, 16),
          suffixIcon: suffix == null ? null : Padding(padding: const EdgeInsets.only(right: 10), child: suffix),
          suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
        ),
      );
}

/// A grouped-input row with a short muted name at its start, for fields that already hold
/// a value (a placeholder alone would vanish). Not a label above the box.
class NamedField extends StatelessWidget {
  const NamedField({super.key, required this.name, required this.controller, this.placeholder = '', this.capitalization = TextCapitalization.none, this.obscure = false, this.keyboard});
  final String name;
  final TextEditingController controller;
  final String placeholder;
  final TextCapitalization capitalization;
  final bool obscure;
  final TextInputType? keyboard;

  @override
  Widget build(BuildContext context) => Row(children: [
        Padding(
          padding: const EdgeInsets.only(left: 17),
          child: SizedBox(width: 92, child: Text(name, style: bodyStyle.copyWith(color: muted))),
        ),
        Expanded(child: BareField(controller: controller, placeholder: placeholder, capitalization: capitalization, obscure: obscure, keyboard: keyboard)),
      ]);
}

/// A pushed screen (replaces bottom sheets for forms): back button alone on its row,
/// 22 gap, kicker, one display line, scrolling content, optional sticky footer.
class PushedPanel extends StatelessWidget {
  const PushedPanel({super.key, this.kicker, required this.title, required this.children, this.footer, this.onBack, this.headerTrailing, this.onRefresh});

  final String? kicker;
  final String title;
  final List<Widget> children;
  final Widget? footer;
  final VoidCallback? onBack;
  final Widget? headerTrailing;

  /// Pull down to load again. Without it the panel does not react to a pull.
  final Future<void> Function()? onRefresh;

  Widget _scrolling() {
    final list = ListView(
      physics: onRefresh == null ? null : const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(gutter, 22, gutter, 28),
      children: [
        if (kicker != null) ...[Kicker(kicker!), const SizedBox(height: 6)],
        Fig(title, style: displayStyle),
        ...children,
      ],
    );
    return onRefresh == null ? list : PullToRefresh(onRefresh: onRefresh!, child: list);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
              child: Row(children: [
                CircleBtn(icon: Ph.arrowLeft, label: 'Back', onTap: onBack ?? () => Navigator.of(context).maybePop()),
                const Spacer(),
                ?headerTrailing,
              ]),
            ),
            Expanded(child: _scrolling()),
            if (footer != null) Padding(padding: const EdgeInsets.fromLTRB(gutter, 10, gutter, 12), child: footer),
          ]),
        ),
      );
}

/// Short choices: a near-full-width card in the middle of the screen. No blur; it fades in
/// with a slight scale rather than arriving from an edge.
Future<T?> showCentredCard<T>(BuildContext context, {required String title, String? subtitle, required Widget Function(BuildContext) builder}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: scrim,
    transitionDuration: const Duration(milliseconds: 170),
    transitionBuilder: (ctx, anim, _, child) {
      final a = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(opacity: a, child: ScaleTransition(scale: Tween(begin: 0.97, end: 1.0).animate(a), child: child));
    },
    pageBuilder: (ctx, _, _) {
      final size = MediaQuery.sizeOf(ctx);
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: math.min(size.width - 36, 480), maxHeight: size.height * 0.72),
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                decoration: surface(radius: rHero, shadow: e4),
                padding: const EdgeInsets.fromLTRB(22, 18, 16, 22),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(title, style: cardTitleStyle)),
                    CircleBtn(icon: Ph.x, label: 'Close', ground: fill, onTap: () => Navigator.of(ctx).pop()),
                  ]),
                  if (subtitle != null) Fig(subtitle, style: labelStyle),
                  const SizedBox(height: 14),
                  Flexible(child: Padding(padding: const EdgeInsets.only(right: 6), child: builder(ctx))),
                ]),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Yes/no in a centred card. Returns true when confirmed.
Future<bool> confirmCard(BuildContext context, {required String title, required String body, required String confirm, String cancel = 'Cancel', bool destructive = false}) async {
  final ok = await showCentredCard<bool>(
    context,
    title: title,
    builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Fig(body, style: bodyStyle),
      const SizedBox(height: 20),
      Row(children: [
        Expanded(child: SecondaryButton(cancel, onTap: () => Navigator.of(ctx).pop(false))),
        const SizedBox(width: 10),
        Expanded(
          child: destructive
              ? SecondaryButton(confirm, tint: danger, onTap: () => Navigator.of(ctx).pop(true))
              : PrimaryButton(confirm, onTap: () => Navigator.of(ctx).pop(true)),
        ),
      ]),
    ]),
  );
  return ok ?? false;
}

/// A one-line status message shown in place (snackbars arrive from the bottom edge, so none here).
class InlineNotice extends StatelessWidget {
  const InlineNotice(this.text, {super.key, this.tone = Tone.warning, this.icon});
  final String text;
  final Tone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      Tone.danger => (dangerSoft, danger),
      Tone.success => (successSoft, success),
      Tone.ai => (aiAccentSoft, aiAccentInk),
      Tone.neutral => (fill, body),
      Tone.warning => (warningSoft, warning),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(rSmall)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (icon != null) ...[Icon(icon, size: 18, color: fg), const SizedBox(width: 10)],
        Expanded(child: Fig(text, style: bodyStyle.copyWith(color: fg, fontWeight: FontWeight.w600))),
      ]),
    );
  }
}

// ---------------------------------------------------------------- selects

/// One option in a choice card. [value] may be null for an "All …" option.
class Choice<T> {
  const Choice(this.value, this.label, {this.count});
  final T? value;
  final String label;

  /// Optional figure beside the option, such as how many questions a chapter has.
  final int? count;
}

/// A centred card listing [options]; returns the one tapped, or null when dismissed. Replaces
/// dropdown menus, which would arrive from an edge.
Future<Choice<T>?> showChoices<T>(BuildContext context,
    {required String title, String? subtitle, required List<Choice<T>> options, required T? selected}) {
  return showCentredCard<Choice<T>>(
    context,
    title: title,
    subtitle: subtitle,
    builder: (ctx) => ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        for (final (i, o) in options.indexed) ...[
          if (i > 0) Container(height: 1, margin: const EdgeInsets.symmetric(horizontal: 4), color: hairline),
          Pressable(
            label: o.label,
            onTap: () => Navigator.of(ctx).pop(o),
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
              decoration: o.value == selected ? BoxDecoration(color: fill, borderRadius: BorderRadius.circular(rSmall)) : null,
              child: Row(children: [
                Expanded(child: Fig(o.label, style: rowTitleStyle)),
                if (o.count != null) ...[const SizedBox(width: 10), Text('${o.count}', style: numStyle(size: 12, color: faint))],
                if (o.value == selected) ...[const SizedBox(width: 10), Icon(Ph.check, size: 18, color: ink)],
              ]),
            ),
          ),
        ],
      ],
    ),
  );
}

/// A filter as a pill: its value and a caret. An applied filter (not "All") takes the filled
/// action ground, so it is obvious what the list is narrowed to.
class SelectPill extends StatelessWidget {
  const SelectPill({super.key, required this.label, required this.onTap, this.active = false, this.count});
  final String label;
  final VoidCallback onTap;
  final bool active;

  /// How many items the current choice shows, set in mono after the label.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final fg = active ? actionInk : body;
    return Pressable(
      label: label,
      onTap: onTap,
      child: Container(
        height: 36,
        padding: const EdgeInsets.fromLTRB(14, 0, 12, 0),
        decoration: active
            ? BoxDecoration(color: actionFill, borderRadius: BorderRadius.circular(rPill), boxShadow: e2)
            : surface(radius: rPill, shadow: e1),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(label, style: chipStyle.copyWith(color: fg), maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (count != null) ...[
            const SizedBox(width: 6),
            Text('$count', style: numStyle(size: 12.5, color: fg.withValues(alpha: 0.75))),
          ],
          const SizedBox(width: 6),
          Icon(Ph.caretDown, size: 13, color: active ? actionInk.withValues(alpha: 0.7) : faint),
        ]),
      ),
    );
  }
}

/// A form field that opens a choice card: the current value (or a faint placeholder) and a caret.
class SelectField extends StatelessWidget {
  const SelectField({super.key, required this.value, required this.onTap, this.placeholder = 'Choose'});
  final String? value;
  final VoidCallback? onTap;
  final String placeholder;

  @override
  Widget build(BuildContext context) => Pressable(
        label: value ?? placeholder,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(17, 15, 15, 15),
          decoration: surface(radius: rCard, shadow: e1),
          child: Row(children: [
            Expanded(
              child: Fig(value ?? placeholder,
                  style: rowTitleStyle.copyWith(fontWeight: FontWeight.w500, fontSize: 15, color: value == null ? faint : (onTap == null ? muted : ink)),
                  maxLines: 2),
            ),
            const SizedBox(width: 10),
            Icon(Ph.caretDown, size: 16, color: faint),
          ]),
        ),
      );
}

/// Filters side by side, wrapping onto a second line when they do not fit.
class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.children, this.padding = const EdgeInsets.symmetric(horizontal: gutter)});
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: padding,
        child: Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 8, children: children)),
      );
}

/// The add action on a tab, labelled and floating above the tab bar, always in the same place.
class FloatingAdd extends StatelessWidget {
  const FloatingAdd(this.label, {super.key, required this.onTap, this.icon = Ph.plus});
  final String label;
  final VoidCallback onTap;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Pressable(
        label: label,
        onTap: onTap,
        child: Container(
          height: 54,
          padding: const EdgeInsets.fromLTRB(18, 0, 22, 0),
          decoration: BoxDecoration(
            color: actionFill,
            borderRadius: BorderRadius.circular(rPill),
            border: isDark ? Border.all(color: const Color(0xFF3A3A46)) : null,
            boxShadow: e4,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 19, color: actionInk),
            const SizedBox(width: 8),
            Text(label, style: buttonStyle.copyWith(color: actionInk)),
          ]),
        ),
      );
}

/// A tab's content with its [FloatingAdd] pinned above the floating tab bar.
class WithFloatingAdd extends StatelessWidget {
  const WithFloatingAdd({super.key, required this.child, required this.add});
  final Widget child;
  final Widget add;

  @override
  Widget build(BuildContext context) => Stack(children: [
        Positioned.fill(child: child),
        // The tab bar sits 12 above the safe area and is 64 tall; this clears it by 14.
        Positioned(right: gutter, bottom: 12 + 64 + 14 + MediaQuery.paddingOf(context).bottom, child: add),
      ]);
}

// ---------------------------------------------------------------- refreshing

/// Pull down to refresh. The list inside needs AlwaysScrollableScrollPhysics so a short
/// list can still be pulled.
class PullToRefresh extends StatelessWidget {
  const PullToRefresh({super.key, required this.onRefresh, required this.child});
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: onRefresh,
        color: ink,
        backgroundColor: card,
        displacement: 36,
        child: child,
      );
}
