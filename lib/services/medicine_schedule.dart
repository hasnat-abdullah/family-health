import 'text_tools.dart';

/// Reads how often and how long from prescription shorthand, by rule rather
/// than by trusting a model's arithmetic. Times match the medicine form's presets.
class MedicineSchedule {
  static const _morning = 8 * 60, _noon = 12 * 60, _afternoon = 14 * 60, _evening = 16 * 60, _night = 20 * 60, _bedtime = 21 * 60;

  /// Dose times in minutes after midnight, or null if [text] isn't understood.
  /// `0+0+0` is understood, and gives no times.
  static List<int>? parseTimes(String? text) {
    if (text == null) return null;
    final t = asciiDigits(text).toLowerCase().trim();
    final dose = r'(\d+(?:[./]\d+)?|½|¼)';
    final grid = RegExp('$dose\\s*[+\\-–—]\\s*$dose\\s*[+\\-–—]\\s*$dose(?:\\s*[+\\-–—]\\s*$dose)?').firstMatch(t);
    if (grid != null) {
      final four = grid[4] != null;
      final slots = four ? const [_morning, _noon, _evening, _night] : const [_morning, _afternoon, _night];
      return [
        for (final (i, slot) in slots.indexed)
          if (!_isZero(grid[i + 1]!)) slot,
      ];
    }
    if (RegExp(r'\b(qid|qds|four times|4 times)\b').hasMatch(t) || t.contains('৪ বার')) return const [_morning, _noon, _evening, _night];
    if (RegExp(r'\b(tds|tid|thrice|three times|3 times)\b').hasMatch(t)) return const [_morning, _afternoon, _night];
    if (RegExp(r'\b(bd|bid|twice|two times|2 times)\b').hasMatch(t)) return const [_morning, _night];
    if (RegExp(r'\b(hs|bedtime|at night|night)\b').hasMatch(t) || t.contains('রাতে')) return const [_bedtime];
    if (t.contains('দিনে ৩') || t.contains('দিনে 3')) return const [_morning, _afternoon, _night];
    if (t.contains('দিনে ২') || t.contains('দিনে 2')) return const [_morning, _night];
    if (RegExp(r'\b(od|once|morning)\b').hasMatch(t) || t.contains('সকালে') || t.contains('দিনে ১') || t.contains('দিনে 1')) return const [_morning];
    return null;
  }

  static bool _isZero(String s) => double.tryParse(s) == 0;

  /// (days, ongoing). Both empty if [text] isn't understood.
  static ({int? days, bool ongoing}) parseDuration(String? text) {
    if (text == null) return (days: null, ongoing: false);
    final t = asciiDigits(text).toLowerCase();
    if (RegExp(r'\b(continue|cont\b|ongoing|long term|lifelong|regular)').hasMatch(t) || t.contains('চলবে') || t.contains('চালিয়ে')) {
      return (days: null, ongoing: true);
    }
    final m = RegExp(r'(\d+)\s*(day|days|d\b|দিন|week|weeks|wk|wks|সপ্তাহ|month|months|mo\b|mon\b|মাস)').firstMatch(t);
    if (m == null) return (days: null, ongoing: false);
    final n = int.parse(m[1]!);
    final unit = m[2]!;
    final days = n * (unit.startsWith('w') || unit == 'সপ্তাহ' ? 7 : (unit.startsWith('mo') || unit == 'মাস' ? 30 : 1));
    return (days: days > 0 && days <= 3650 ? days : null, ongoing: false);
  }
}
