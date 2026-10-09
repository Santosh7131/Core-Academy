import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// The launcher icon's mark: a "C" around a solid core, drawn on the icon's 108-unit canvas.
/// [arc] and [dot] run from 0 (not drawn yet) to 1 (done), so the opening can draw it in.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40, this.arc = 1, this.dot = 1, this.color});
  final double size;
  final double arc;
  final double dot;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _MarkPainter(arc: arc, dot: dot, color: color ?? ink)),
      );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter({required this.arc, required this.dot, required this.color});
  final double arc;
  final double dot;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Nudged right because the open side of the C reads lighter.
    final unit = size.width / 108;
    final center = Offset(size.width / 2 + 1.5 * unit, size.height / 2);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.5 * unit
      ..strokeCap = StrokeCap.round;
    // The C opens to the right: it starts 40 degrees above the horizontal and turns counter-clockwise.
    const start = -40 * math.pi / 180;
    const sweep = -280 * math.pi / 180;
    if (arc > 0) canvas.drawArc(Rect.fromCircle(center: center, radius: 22 * unit), start, sweep * arc, false, stroke);
    if (dot > 0) canvas.drawCircle(center, 6.5 * unit * dot.clamp(0.0, 1.2), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.arc != arc || old.dot != dot || old.color != color;
}
