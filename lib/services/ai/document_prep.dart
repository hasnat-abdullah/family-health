import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import '../../data/models.dart';
import '../../data/storage.dart';
import '../image_tools.dart';
import '../report_reader.dart';
import 'ai_client.dart';

class PreparedDocument {
  PreparedDocument(this.images, this.lines, this.skippedPages);
  final List<AiImage> images;
  final List<String> lines;

  /// Pages past the limit, which the AI did not see.
  final int skippedPages;
}

/// Gets stored originals ready for an AI: every page as a sized JPEG, which
/// works the same on every provider, plus independently read text for checking.
class DocumentPrep {
  static const _maxPages = ReportReader.maxPdfPages;
  static const _maxSide = 1800;

  /// [lines] skips the on-device read when the caller already has it.
  static Future<PreparedDocument> prepare(
    List<Attachment> attachments, {
    required bool withImages,
    List<String>? lines,
    AiCancelToken? cancel,
  }) async {
    final images = <AiImage>[];
    final text = <String>[...?lines];
    var skipped = 0;
    for (final a in attachments) {
      cancel?.throwIfCancelled();
      if (lines == null) {
        try {
          text.addAll(await FileStore.instance.withPlainFile(a, ReportReader.readLines));
        } catch (_) {
          // The AI can still read it; the review will say it couldn't be cross-checked.
        }
      }
      if (!withImages) continue;
      final bytes = await FileStore.instance.read(a);
      try {
        if (a.isPdf) {
          skipped += await _addPdf(bytes, images);
        } else if (images.length < _maxPages) {
          images.add(AiImage(await ImageTools.toJpeg(bytes, maxSide: _maxSide), 'image/jpeg'));
        } else {
          skipped++;
        }
      } on AiException {
        rethrow;
      } catch (e) {
        throw AiException(AiErrorKind.unsupported, detail: "${a.originalName}: $e");
      }
    }
    return PreparedDocument(images, text, skipped);
  }

  static Future<int> _addPdf(Uint8List bytes, List<AiImage> images) async {
    final doc = await PdfDocument.openData(bytes);
    try {
      for (final page in doc.pages) {
        if (images.length >= _maxPages) return doc.pages.length - doc.pages.indexOf(page);
        final longest = page.width > page.height ? page.width : page.height;
        final scale = _maxSide / longest;
        final rendered = await page.render(
          fullWidth: page.width * scale,
          fullHeight: page.height * scale,
          backgroundColor: 0xffffffff,
        );
        if (rendered == null) throw StateError('Could not render page ${page.pageNumber}');
        try {
          final image = await rendered.createImage();
          final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          final (w, h) = (image.width, image.height);
          image.dispose();
          images.add(AiImage(await ImageTools.rgbaToJpeg(rgba!.buffer.asUint8List(), w, h, 85), 'image/jpeg'));
        } finally {
          rendered.dispose();
        }
      }
      return 0;
    } finally {
      await doc.dispose();
    }
  }
}
