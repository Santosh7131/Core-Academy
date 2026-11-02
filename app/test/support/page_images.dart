// Made-up page pictures for the tests. A page is a PNG with coloured blocks where the test says, handed out by address instead of
// downloaded, so a cut can be told by its colours and no network is involved.
//
// The tests run on fake time, where a picture being decoded never finishes by itself. So the pages are decoded first, on the real
// event loop (`await t.runAsync(fake.warm)`), and the screen then finds them ready. Cutting a figure out of a page is the same
// kind of work: see `settle`.
import 'dart:ui' as ui;

import 'package:core_academy/features/teacher/page_pictures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// A coloured block on a page: a box as fractions of it.
typedef Block = ({PageBox box, Color color});

const red = Color(0xFFD32F2F);
const blue = Color(0xFF1976D2);
const white = Color(0xFFFFFFFF);

/// A page as PNG bytes: white, with [blocks] on it. Needs the real event loop.
Future<Uint8List> pagePng({int width = 600, int height = 800, List<Block> blocks = const []}) async {
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  c.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = white);
  for (final b in blocks) {
    c.drawRect(Rect.fromLTRB(b.box[0] * width, b.box[1] * height, b.box[2] * width, b.box[3] * height), Paint()..color = b.color);
  }
  final img = await recorder.endRecording().toImage(width, height);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// The size of a PNG, in pixels. Needs the real event loop.
Future<Size> sizeOfPng(Uint8List png) async {
  final img = await decodeImageFromList(png);
  return Size(img.width.toDouble(), img.height.toDouble());
}

/// The colour of the pixel at fractions ([x], [y]) of a PNG. Needs the real event loop.
Future<Color> pixelOfPng(Uint8List png, double x, double y) async {
  final img = await decodeImageFromList(png);
  final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final col = (x * img.width).floor().clamp(0, img.width - 1);
  final row = (y * img.height).floor().clamp(0, img.height - 1);
  final at = (row * img.width + col) * 4;
  return Color.fromARGB(data.getUint8(at + 3), data.getUint8(at), data.getUint8(at + 1), data.getUint8(at + 2));
}

/// A paper's pages as pictures the screens find by address: `https://pages.test/p1.png` for page 1.
class FakePages {
  FakePages(this.pages);

  /// Page number to its PNG.
  final Map<int, Uint8List> pages;

  /// The addresses asked for so far, one entry per download.
  final fetched = <String>[];

  /// Addresses that cannot be loaded (the download gives nothing).
  final broken = <String>{};

  String url(int n) => 'https://pages.test/p$n.png';

  /// The page rows the server sends: each with its address.
  List<Map<String, dynamic>> rows({Set<int> without = const {}}) => [
        for (final n in pages.keys) {'page_no': n, 'object_key': 'k$n', 'uploaded': true, 'ai_status': 'done', 'ai_error': null, 'answer_key': null, 'image_url': without.contains(n) ? null : url(n)},
      ];

  late final PaperPictures pictures = _make();

  PaperPictures _make() {
    final p = PaperPictures(fetch: (address) async {
      fetched.add(address);
      if (broken.contains(address)) return null;
      final n = int.parse(RegExp(r'p(\d+)\.png').firstMatch(address)!.group(1)!);
      return pages[n];
    });
    p.setPages(rows());
    return p;
  }

  /// Decodes every page now. Run it inside `runAsync`.
  Future<void> warm() async {
    for (final n in pages.keys) {
      await pictures.image(n);
    }
  }
}

/// Lets a picture be found at [url] by `Image.network`, without a download.
Future<void> cacheNetworkImage(WidgetTester t, String url, Uint8List png) async {
  final img = await t.runAsync(() => decodeImageFromList(png));
  imageCache.putIfAbsent(NetworkImage(url), () => OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: img!))));
}

/// Forgets the pictures kept for `Image.network`. Call it in a tearDown.
void forgetNetworkImages() {
  imageCache.clear();
  imageCache.clearLiveImages();
}

/// Lets work that waits on the engine (a page being cut, a picture being encoded) run to its end: the real event loop turns for a
/// moment, then the screen takes what came back. A few rounds, because one step often starts the next.
Future<void> settle(WidgetTester t, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 60));
  }
}
