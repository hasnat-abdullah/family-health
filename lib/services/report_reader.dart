import 'dart:io';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:report_ocr/report_ocr.dart';

/// Turns an original report file into text lines, entirely on-device.
///
/// PDFs with a text layer are read directly (exact). Scanned PDFs and photos
/// go through OCR.
class ReportReader {
  static const maxPdfPages = 10;

  static Future<List<String>> readLines(File file) async {
    if (p.extension(file.path).toLowerCase() == '.pdf') return _readPdf(file);
    return ReportOcr.toLines(await ReportOcr.recognize(file.path));
  }

  static Future<List<String>> _readPdf(File file) async {
    final doc = await PdfDocument.openFile(file.path);
    try {
      final pages = doc.pages.take(maxPdfPages).toList();
      final lines = <String>[];
      for (final page in pages) {
        final text = await page.loadText();
        lines.addAll((text?.fullText ?? '').split(RegExp(r'\r?\n')));
      }
      final hasText = lines.where((l) => l.trim().isNotEmpty).length > 3;
      if (hasText) return lines;

      // Scanned PDF: render each page and OCR it.
      final ocrLines = <String>[];
      final tmp = await getTemporaryDirectory();
      for (final page in pages) {
        final png = File(p.join(tmp.path, 'ocr_page_${page.pageNumber}.png'));
        await _renderPage(page, png);
        ocrLines.addAll(ReportOcr.toLines(await ReportOcr.recognize(png.path)));
        await png.delete();
      }
      return ocrLines;
    } finally {
      await doc.dispose();
    }
  }

  static Future<void> _renderPage(PdfPage page, File out) async {
    // ~200 dpi is plenty for OCR.
    const scale = 200 / 72;
    final rendered = await page.render(
      fullWidth: page.width * scale,
      fullHeight: page.height * scale,
      backgroundColor: 0xffffffff,
    );
    if (rendered == null) throw StateError('Could not render PDF page ${page.pageNumber}');
    try {
      final image = await rendered.createImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await out.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      rendered.dispose();
    }
  }
}
