// Pages that look printed, for the picture harness: serif text, numbered questions and a diagram, drawn to PNG. Where each question
// and figure sits comes back as fractions of the page, so the boxes a scene hands to a draft are the ones that were drawn.
// These are made-up pages for pictures; nothing here is from a real paper.
import 'dart:ui' as ui;

import 'package:core_academy/features/teacher/page_pictures.dart' show PageBox;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// The maths package's serif face (the harness loads it), which reads like type on paper.
const _serif = 'packages/flutter_math_fork/KaTeX_Main';
const _ink = Color(0xFF1A1A1E);

/// A page drawn top to bottom.
class PrintedPage {
  PrintedPage({this.width = 1240, this.height = 1754, String? header}) {
    _canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
    _y = height * 0.055;
    if (header != null) {
      _y = _paragraph(header, x: margin, size: 28, color: const Color(0xFF55555C), maxWidth: width - 2 * margin);
      _canvas.drawLine(Offset(margin, _y + 10), Offset(width - margin, _y + 10), Paint()..color = const Color(0xFF9A9AA2)..strokeWidth = 2);
      _y += 56;
    }
  }

  final int width;
  final int height;

  /// Where each question, continuation or figure sits, by the id it was drawn with.
  final boxes = <String, PageBox>{};

  final _recorder = ui.PictureRecorder();
  late final _canvas = Canvas(_recorder);
  double _y = 0;

  double get margin => width * 0.09;
  double get _numberWidth => width * 0.055;

  /// Draws [text] wrapped to [maxWidth] with its top at the current line; returns where it ends.
  double _paragraph(String text, {required double x, double size = 34, FontWeight weight = FontWeight.w400, Color color = _ink, required double maxWidth}) {
    final tp = TextPainter(
      // Geist fills in what the serif face lacks: the middle dot, the little raised 2.
      text: TextSpan(text: text, style: TextStyle(fontFamily: _serif, fontFamilyFallback: const ['Geist'], fontSize: size, fontWeight: weight, color: color, height: 1.38)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    tp.paint(_canvas, Offset(x, _y));
    return _y + tp.height;
  }

  PageBox _fractions(Rect r) => [
        (r.left / width).clamp(0.0, 1.0),
        (r.top / height).clamp(0.0, 1.0),
        (r.right / width).clamp(0.0, 1.0),
        (r.bottom / height).clamp(0.0, 1.0),
      ];

  /// Moves down by a fraction of the page's height.
  void space(double fraction) => _y += height * fraction;

  /// A numbered question: its words, a figure if there is one, and its options in two columns. Its box is recorded under [id], and
  /// the figure's under `'$id.figure'`.
  void question(String id, String number, String stem, {List<String> options = const [], void Function(Canvas, Rect)? figure, double figureHeight = 0.11}) {
    final top = _y;
    final textX = margin + _numberWidth;
    final textWidth = width - margin - textX;
    _paragraph('$number.', x: margin, weight: FontWeight.w700, maxWidth: _numberWidth);
    _y = _paragraph(stem, x: textX, maxWidth: textWidth) + 14;
    if (figure != null) {
      final r = Rect.fromLTWH(textX, _y, textWidth * 0.62, height * figureHeight);
      figure(_canvas, r);
      boxes['$id.figure'] = _fractions(r.inflate(6));
      _y = r.bottom + 18;
    }
    _options(options, textX, textWidth);
    boxes[id] = _fractions(Rect.fromLTRB(margin - 10, top - 8, width - margin + 10, _y + 4));
    _y += height * 0.028;
  }

  /// The end of a question that began on the page before: its remaining options, at the top of this page.
  void continuation(String id, List<String> options) {
    final top = _y;
    final textX = margin + _numberWidth;
    _options(options, textX, width - margin - textX);
    boxes[id] = _fractions(Rect.fromLTRB(margin - 10, top - 8, width - margin + 10, _y + 4));
    _y += height * 0.028;
  }

  void _options(List<String> options, double x, double w) {
    for (var i = 0; i < options.length; i += 2) {
      final left = _paragraph(options[i], x: x, maxWidth: w / 2 - 12);
      var bottom = left;
      if (i + 1 < options.length) {
        final yBefore = _y;
        bottom = _paragraph(options[i + 1], x: x + w / 2, maxWidth: w / 2 - 12);
        _y = yBefore;
        bottom = bottom > left ? bottom : left;
      }
      _y = bottom + 6;
    }
  }

  Future<Uint8List> png() async {
    final img = await _recorder.endRecording().toImage(width, height);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }
}

/// A circuit: two resistors in parallel, one in series, as a line drawing in [r].
void drawCircuit(Canvas canvas, Rect r) {
  final sx = r.width / 560;
  final sy = r.height / 240;
  Offset p(double x, double y) => Offset(r.left + x * sx, r.top + y * sy);
  final line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 3 * (sx + sy) / 2
    ..color = _ink;
  void seg(double x1, double y1, double x2, double y2) => canvas.drawLine(p(x1, y1), p(x2, y2), line);
  void box(double x, double y) => canvas.drawRect(Rect.fromPoints(p(x, y), p(x + 80, y + 32)), line);
  void dot(double x, double y) => canvas.drawCircle(p(x, y), 7 * sx, Paint()..color = _ink);
  void label(String s, double x, double y) {
    final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(fontFamily: _serif, fontSize: 26 * sy, color: _ink)), textDirection: TextDirection.ltr)..layout();
    tp.paint(canvas, p(x, y - 24));
  }

  dot(40, 120);
  label('A', 22, 190);
  seg(40, 120, 110, 120);
  box(110, 104);
  label('2 Ω', 130, 98);
  seg(190, 120, 240, 120);
  seg(240, 50, 240, 190);
  seg(240, 50, 290, 50);
  box(290, 34);
  label('3 Ω', 310, 32);
  seg(370, 50, 420, 50);
  seg(240, 190, 290, 190);
  box(290, 174);
  label('6 Ω', 310, 232);
  seg(370, 190, 420, 190);
  seg(420, 50, 420, 190);
  seg(420, 120, 520, 120);
  dot(520, 120);
  label('B', 508, 190);
}
