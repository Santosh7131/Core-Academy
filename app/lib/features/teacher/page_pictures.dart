import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/api.dart';
import '../../theme.dart';
import '../../ui/kit.dart';

/// A box on a page as four fractions of it: left, top, right, bottom, with 0,0 at the page's top left corner.
typedef PageBox = List<double>;

/// A box the server sent ([x1, y1, x2, y2] of numbers), or null when it is not one.
PageBox? pageBoxOf(Object? raw) {
  if (raw is! List || raw.length != 4 || raw.any((v) => v is! num)) return null;
  final b = [for (final v in raw) (v as num).toDouble()];
  return b[2] > b[0] && b[3] > b[1] ? b : null;
}

/// A page and a box on it, from the server's `{"page": 2, "box": [...]}`.
({int page, PageBox box})? placedOf(Object? raw) {
  if (raw is! Map || raw['page'] is! int) return null;
  final box = pageBoxOf(raw['box']);
  return box == null ? null : (page: raw['page'] as int, box: box);
}

/// Where a question is printed, one entry per page it is on (two when it ran over the page edge).
List<({int page, PageBox box})> questionParts(Map<String, dynamic> draft) {
  final raw = draft['question_boxes'];
  if (raw is! List) return const [];
  return [for (final p in raw) ?placedOf(p)];
}

/// A paper's page pictures, each loaded once. The check list and the editor show parts of them, and a figure is cut out of one.
class PaperPictures {
  PaperPictures({Future<Uint8List?> Function(String url)? fetch}) : _fetch = fetch ?? _download;

  final Future<Uint8List?> Function(String url) _fetch;
  final Map<int, String> _urls = {};

  /// The pages decoded so far. A page is 14 MB once decoded, so only the last few are kept; a picture on screen
  /// holds its own page for as long as it needs it.
  final LinkedHashMap<int, Future<ui.Image?>> _images = LinkedHashMap();
  static const _kept = 4;

  /// Takes the paper's page list (each page with its `image_url`, or null while it is not uploaded).
  void setPages(List<Map<String, dynamic>> pages) {
    for (final pg in pages) {
      final url = pg['image_url'];
      if (pg['page_no'] is int && url is String) _urls[pg['page_no'] as int] = url;
    }
  }

  String? url(int page) => _urls[page];

  /// The page as a picture, or null when it has no picture or it could not be loaded (asking again tries again).
  Future<ui.Image?> image(int page) {
    final url = _urls[page];
    if (url == null) return Future.value(null);
    final have = _images.remove(page);
    final future = have ?? _load(url).then((img) {
      if (img == null) _images.remove(page);
      return img;
    });
    _images[page] = future;
    while (_images.length > _kept) {
      _images.remove(_images.keys.first);
    }
    return future;
  }

  Future<ui.Image?> _load(String url) async {
    try {
      final bytes = await _fetch(url);
      if (bytes == null) return null;
      final codec = await ui.instantiateImageCodec(bytes);
      return (await codec.getNextFrame()).image;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _download(String url) async {
    final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 40));
    return res.statusCode == 200 ? res.bodyBytes : null;
  }
}

/// The part of a page picture inside [box], as PNG bytes (a drawing stays sharp as a PNG). [margin] adds room around it as a
/// fraction of the page's width.
Future<Uint8List?> cutOut(ui.Image page, PageBox box, {double margin = 0}) async {
  final w = page.width.toDouble();
  final h = page.height.toDouble();
  final src = Rect.fromLTRB(
    (box[0] - margin).clamp(0.0, 1.0) * w,
    (box[1] - margin * w / h).clamp(0.0, 1.0) * h,
    (box[2] + margin).clamp(0.0, 1.0) * w,
    (box[3] + margin * w / h).clamp(0.0, 1.0) * h,
  );
  final outW = src.width.round().clamp(1, 4000);
  final outH = src.height.round().clamp(1, 4000);
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(page, src, Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()), Paint()..filterQuality = FilterQuality.high);
  final img = await recorder.endRecording().toImage(outW, outH);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data?.buffer.asUint8List();
}

/// Uploads a figure cut out of a page. Returns its storage key.
Future<String> uploadFigure(Uint8List png) async {
  final up = await api.post('/teacher/uploads', {'size': png.length, 'type': 'png'});
  await api.putBytes('${up['put_url']}', png, contentType: 'image/png');
  return '${up['key']}';
}

/// A piece of a page picture: the part inside [box], a little wider so a cut line is never the question's edge.
class PagePiece extends StatefulWidget {
  const PagePiece({super.key, required this.pictures, required this.page, required this.box});
  final PaperPictures pictures;
  final int page;
  final PageBox box;

  @override
  State<PagePiece> createState() => _PagePieceState();
}

class _PagePieceState extends State<PagePiece> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(PagePiece old) {
    super.didUpdateWidget(old);
    if (old.page != widget.page) _load();
  }

  void _load() {
    setState(() {
      _image = null;
      _failed = false;
    });
    widget.pictures.image(widget.page).then((img) {
      if (mounted) {
        setState(() {
          _image = img;
          _failed = img == null;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    if (img == null) {
      return Pressable(
        onTap: _failed ? _load : null,
        label: _failed ? 'Try loading the page again' : 'Loading the page',
        child: Container(
          height: 76,
          alignment: Alignment.center,
          child: Fig(_failed ? 'The page did not load. Tap to try again.' : 'Loading the page', style: labelStyle.copyWith(color: const Color(0xFF85858F))),
        ),
      );
    }
    final w = img.width.toDouble();
    final h = img.height.toDouble();
    final b = widget.box;
    final src = Rect.fromLTRB(
      (b[0] - 0.012).clamp(0.0, 1.0) * w,
      (b[1] - 0.007).clamp(0.0, 1.0) * h,
      (b[2] + 0.012).clamp(0.0, 1.0) * w,
      (b[3] + 0.007).clamp(0.0, 1.0) * h,
    );
    return Semantics(
      image: true,
      label: 'The question as printed on page ${widget.page}',
      child: AspectRatio(aspectRatio: src.width / src.height, child: CustomPaint(painter: _PiecePainter(img, src))),
    );
  }
}

class _PiecePainter extends CustomPainter {
  _PiecePainter(this.image, this.src);
  final ui.Image image;
  final Rect src;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium..isAntiAlias = true);
  }

  @override
  bool shouldRepaint(_PiecePainter old) => old.image != image || old.src != src;
}

const _paperInk = Color(0xFF85858F);
const _paperEdge = Color(0xFFE1E1E7);

/// "From your paper": the question as it is printed, on a white card like the paper itself, with a way to see its whole page.
class FromYourPaper extends StatelessWidget {
  const FromYourPaper({super.key, required this.pictures, required this.parts, required this.onWholePage});
  final PaperPictures pictures;
  final List<({int page, PageBox box})> parts;
  final void Function(int page) onWholePage;

  @override
  Widget build(BuildContext context) {
    final pages = [for (final p in parts) p.page];
    final label = pages.length == 1 ? 'page ${pages.first}' : 'pages ${pages.sublist(0, pages.length - 1).join(', ')} and ${pages.last}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.fromLTRB(11, 10, 11, 11),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _paperEdge),
          boxShadow: const [BoxShadow(color: Color(0x0D000000), blurRadius: 2, offset: Offset(0, 1))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Ph.image, size: 13, color: _paperInk),
            const SizedBox(width: 6),
            Expanded(child: Text('FROM YOUR PAPER', style: kickerStyle.copyWith(color: _paperInk, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis)),
            Fig(label, style: labelStyle.copyWith(color: _paperInk, fontSize: 11), numColor: _paperInk),
          ]),
          const SizedBox(height: 7),
          for (final (i, p) in parts.indexed) ...[
            if (i > 0) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Expanded(child: Divider(height: 1, color: _paperEdge)),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Fig('page ${p.page}', style: labelStyle.copyWith(color: _paperInk, fontSize: 10.5), numColor: _paperInk)),
                const Expanded(child: Divider(height: 1, color: _paperEdge)),
              ]),
              const SizedBox(height: 6),
            ],
            PagePiece(pictures: pictures, page: p.page, box: p.box),
          ],
        ]),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: Pressable(
          onTap: () => onWholePage(parts.first.page),
          label: 'See the whole page',
          child: Padding(
            padding: const EdgeInsets.only(top: 9, bottom: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Ph.arrowsOutSimple, size: 14, color: muted),
              const SizedBox(width: 6),
              Flexible(child: Fig('See the whole page', style: labelStyle.copyWith(color: muted, fontWeight: FontWeight.w600, fontSize: 12.5))),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// A figure cut from a page: the picture with where it came from and what can be done to it.
class CutFigure extends StatelessWidget {
  const CutFigure({super.key, required this.url, required this.caption, this.onCutAgain, this.onRemove});
  final String url;
  final String caption;
  final VoidCallback? onCutAgain;
  final VoidCallback? onRemove;

  Widget _tool(String label, IconData icon, VoidCallback? onTap) => Pressable(
        onTap: onTap,
        label: label,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(color: const Color(0xFFF1F1F4), borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: const Color(0xFF26262B)),
            const SizedBox(width: 5),
            Text(label, style: tagStyle.copyWith(fontSize: 11.5, color: const Color(0xFF26262B), fontWeight: FontWeight.w700), maxLines: 1),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _paperEdge)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: Image.network(url, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox(height: 60, child: Center(child: Icon(Ph.image, color: _paperInk)))),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Ph.image, size: 13, color: _paperInk),
              const SizedBox(width: 6),
              Text(caption.toUpperCase(), style: kickerStyle.copyWith(color: _paperInk, fontSize: 10), maxLines: 1),
            ]),
            if (onCutAgain != null) _tool('Cut again', Ph.scissors, onCutAgain),
            if (onRemove != null) _tool('Remove', Ph.x, onRemove),
          ]),
        ]),
      );
}

/// The whole of one page, to look at: pinch to zoom.
class WholePageScreen extends StatelessWidget {
  const WholePageScreen({super.key, required this.url, required this.n});
  final String url;
  final int n;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
              child: Row(children: [
                CircleBtn(icon: Ph.arrowLeft, label: 'Back', onTap: () => Navigator.of(context).pop()),
                const SizedBox(width: 14),
                Fig('Page $n', style: sectionStyle),
              ]),
            ),
            Expanded(child: InteractiveViewer(maxScale: 5, child: Center(child: Image.network(url)))),
          ]),
        ),
      );
}

enum _Grab { topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move }

/// "Cut the diagram": the page, with a box to drag so it holds only the figure. It shows the page across the screen's whole width,
/// as much of it as the screen holds around the box (all of it when it fits, which it does on most phones); "Show more of the
/// page" widens what is shown when only a part fits. Pops with the new box.
class FigureCutScreen extends StatefulWidget {
  const FigureCutScreen({super.key, required this.pictures, required this.page, required this.start});
  final PaperPictures pictures;
  final int page;

  /// Where the box starts, as fractions of the page.
  final PageBox start;

  @override
  State<FigureCutScreen> createState() => _FigureCutScreenState();
}

class _FigureCutScreenState extends State<FigureCutScreen> {
  ui.Image? _image;
  bool _failed = false;
  late Rect _box = Rect.fromLTRB(widget.start[0], widget.start[1], widget.start[2], widget.start[3]);

  /// The band of the page that is shown, as fractions of the page's height. Until the screen is measured it is a little around the
  /// box; then [_fit] widens it to what the screen holds.
  late double _top = math.max(0, _box.top - 0.06);
  late double _bottom = math.min(1, _box.bottom + 0.06);
  bool _fitted = false;
  _Grab? _grab;

  static const _minW = 0.06;
  static const _minH = 0.04;

  @override
  void initState() {
    super.initState();
    widget.pictures.image(widget.page).then((img) {
      if (mounted) {
        setState(() {
          _image = img;
          _failed = img == null;
        });
      }
    });
  }

  bool get _all => _top <= 0 && _bottom >= 1;

  /// The first time the page is laid out: the band that fills the room there is at full width, centred on the box. When the whole
  /// page fits, that is all of it.
  void _fit(ui.Image img, BoxConstraints c) {
    if (_fitted) return;
    _fitted = true;
    final pageHeight = (c.maxWidth - 2 * gutter) * img.height / img.width;
    final share = pageHeight <= 0 ? 1.0 : c.maxHeight / pageHeight;
    if (share >= 1) {
      _top = 0;
      _bottom = 1;
    } else {
      final top = (((_box.top + _box.bottom) / 2) - share / 2).clamp(0.0, 1 - share);
      _top = math.min(top, _box.top);
      _bottom = math.max(top + share, _box.bottom);
    }
    // "Show more of the page" below depends on what is shown, and is built before this: build it again, now that it is known.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _showMore() => setState(() {
        _top = math.max(0, _top - 0.14);
        _bottom = math.min(1, _bottom + 0.14);
      });

  /// The box in pixels of the band as drawn at [size].
  Rect _px(Size size) => Rect.fromLTRB(
        _box.left * size.width,
        (_box.top - _top) / (_bottom - _top) * size.height,
        _box.right * size.width,
        (_box.bottom - _top) / (_bottom - _top) * size.height,
      );

  Map<_Grab, Offset> _handles(Rect r) => {
        _Grab.topLeft: r.topLeft,
        _Grab.top: r.topCenter,
        _Grab.topRight: r.topRight,
        _Grab.right: r.centerRight,
        _Grab.bottomRight: r.bottomRight,
        _Grab.bottom: r.bottomCenter,
        _Grab.bottomLeft: r.bottomLeft,
        _Grab.left: r.centerLeft,
      };

  void _start(Offset at, Size size) {
    final r = _px(size);
    _Grab? best;
    var bestDist = 34.0;
    for (final e in _handles(r).entries) {
      final d = (e.value - at).distance;
      if (d < bestDist) {
        best = e.key;
        bestDist = d;
      }
    }
    _grab = best ?? (r.inflate(6).contains(at) ? _Grab.move : null);
  }

  void _drag(Offset delta, Size size) {
    final g = _grab;
    if (g == null) return;
    final dx = delta.dx / size.width;
    final dy = delta.dy / size.height * (_bottom - _top);
    var l = _box.left, t = _box.top, r = _box.right, b = _box.bottom;
    switch (g) {
      case _Grab.move:
        final w = r - l, h = b - t;
        l = (l + dx).clamp(0.0, 1 - w);
        t = (t + dy).clamp(_top, _bottom - h);
        r = l + w;
        b = t + h;
      case _Grab.topLeft:
        l += dx;
        t += dy;
      case _Grab.top:
        t += dy;
      case _Grab.topRight:
        r += dx;
        t += dy;
      case _Grab.right:
        r += dx;
      case _Grab.bottomRight:
        r += dx;
        b += dy;
      case _Grab.bottom:
        b += dy;
      case _Grab.bottomLeft:
        l += dx;
        b += dy;
      case _Grab.left:
        l += dx;
    }
    l = l.clamp(0.0, r - _minW);
    r = r.clamp(l + _minW, 1.0);
    t = t.clamp(_top, b - _minH);
    b = b.clamp(t + _minH, _bottom);
    setState(() => _box = Rect.fromLTRB(l, t, r, b));
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 8, gutter, 0),
            child: Row(children: [
              CircleBtn(icon: Ph.arrowLeft, label: 'Back', onTap: () => Navigator.of(context).pop()),
              const SizedBox(width: 14),
              Expanded(child: Fig('Cut the diagram', style: sectionStyle)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 12, gutter, 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Fig('Drag the corners and sides so the box holds only the diagram.', style: bodyStyle.copyWith(color: muted)),
            ),
          ),
          Expanded(
            child: img == null
                ? Center(child: Fig(_failed ? 'The page did not load.' : 'Loading the page', style: bodyStyle.copyWith(color: muted)))
                : LayoutBuilder(builder: (context, c) {
                    _fit(img, c);
                    final aspect = img.width / (img.height * (_bottom - _top));
                    final w = math.min(c.maxWidth - 2 * gutter, c.maxHeight * aspect);
                    final size = Size(w, w / aspect);
                    return Center(
                      child: SizedBox(
                        width: size.width,
                        height: size.height,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (d) => _start(d.localPosition, size),
                          onPanUpdate: (d) => _drag(d.delta, size),
                          onPanEnd: (_) => _grab = null,
                          child: CustomPaint(painter: _CutPainter(img, _top, _bottom, _px(size), _handles(_px(size)).values.toList())),
                        ),
                      ),
                    );
                  }),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(gutter, 12, gutter, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (!_all) ...[
                SecondaryButton('Show more of the page', icon: Ph.arrowsOutSimple, onTap: _showMore),
                const SizedBox(height: 10),
              ],
              PrimaryButton('Use this cut', icon: Ph.scissors, onTap: img == null ? null : () => Navigator.of(context).pop(<double>[_box.left, _box.top, _box.right, _box.bottom])),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _CutPainter extends CustomPainter {
  _CutPainter(this.image, this.top, this.bottom, this.box, this.handles);
  final ui.Image image;
  final double top;
  final double bottom;
  final Rect box;
  final List<Offset> handles;

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTRB(0, top * image.height, image.width.toDouble(), bottom * image.height);
    canvas.drawImageRect(image, src, Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
    // Everything outside the box is dimmed, so what will be cut stands out.
    final outside = Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), Path()..addRect(box));
    canvas.drawPath(outside, Paint()..color = const Color(0x73000000));
    canvas.drawRect(box, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = aiAccent);
    for (final h in handles) {
      canvas.drawCircle(h, 8, Paint()..color = Colors.white);
      canvas.drawCircle(h, 8, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = aiAccent);
    }
  }

  @override
  bool shouldRepaint(_CutPainter old) => old.image != image || old.top != top || old.bottom != bottom || old.box != box;
}
