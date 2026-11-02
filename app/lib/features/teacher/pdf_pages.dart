import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';

/// The most pages one paper has.
const maxPaperPages = 20;

/// How many pages a PDF has. Throws when it cannot be opened.
Future<int> pdfPageCount(Uint8List bytes) async {
  final doc = await PdfDocument.openData(bytes);
  try {
    return doc.pagesCount;
  } finally {
    await doc.close();
  }
}

/// A PDF's first [limit] pages as JPEGs 1600 px wide, drawn on the phone. [progress] hears of each page as it starts.
/// Throws when the PDF cannot be opened.
Future<List<Uint8List>> renderPdfPages(Uint8List bytes, {int limit = maxPaperPages, void Function(int page, int of)? progress}) async {
  final doc = await PdfDocument.openData(bytes);
  try {
    final n = doc.pagesCount.clamp(0, limit);
    final out = <Uint8List>[];
    for (var i = 1; i <= n; i++) {
      progress?.call(i, n);
      final page = await doc.getPage(i);
      try {
        final scale = 1600 / page.width;
        final img = await page.render(
          width: page.width * scale,
          height: page.height * scale,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#FFFFFF',
          quality: 80,
        );
        if (img != null) out.add(img.bytes);
      } finally {
        await page.close();
      }
    }
    return out;
  } finally {
    await doc.close();
  }
}
