import 'package:flutter/services.dart';

/// A piece of recognised text with its bounding box, normalised to 0..1 with
/// the origin at the top-left of the image.
class OcrBlock {
  const OcrBlock(this.text, this.left, this.top, this.width, this.height);

  final String text;
  final double left;
  final double top;
  final double width;
  final double height;

  double get centerY => top + height / 2;

  factory OcrBlock.fromMap(Map<Object?, Object?> m) => OcrBlock(
    m['text'] as String,
    (m['x'] as num).toDouble(),
    (m['y'] as num).toDouble(),
    (m['w'] as num).toDouble(),
    (m['h'] as num).toDouble(),
  );
}

/// On-device text recognition. Nothing leaves the device:
/// Apple Vision on iOS/macOS, Google ML Kit (bundled model) on Android.
class ReportOcr {
  static const _channel = MethodChannel('report_ocr');

  /// Recognises text in the image at [path] and returns line-level blocks.
  static Future<List<OcrBlock>> recognize(String path) async {
    final raw = await _channel.invokeListMethod<Object?>('recognize', {'path': path});
    return (raw ?? const []).map((e) => OcrBlock.fromMap(e as Map<Object?, Object?>)).toList();
  }

  /// Rebuilds visual rows from blocks so table-style lab reports read as
  /// "Hemoglobin   11.2   g/dL   12.0 - 15.5" instead of one column at a time.
  static List<String> toLines(List<OcrBlock> blocks) {
    if (blocks.isEmpty) return const [];
    final sorted = [...blocks]..sort((a, b) => a.centerY.compareTo(b.centerY));
    final heights = sorted.map((b) => b.height).toList()..sort();
    final tolerance = heights[heights.length ~/ 2] * 0.6;

    final rows = <List<OcrBlock>>[];
    for (final block in sorted) {
      final row = rows.isEmpty ? null : rows.last;
      if (row != null) {
        final rowY = row.map((b) => b.centerY).reduce((a, b) => a + b) / row.length;
        if ((block.centerY - rowY).abs() <= tolerance) {
          row.add(block);
          continue;
        }
      }
      rows.add([block]);
    }
    return [for (final row in rows) (row..sort((a, b) => a.left.compareTo(b.left))).map((b) => b.text).join('   ')];
  }
}
