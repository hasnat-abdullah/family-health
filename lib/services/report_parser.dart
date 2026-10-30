import '../data/lab_catalog.dart';
import 'text_tools.dart';

/// A value pulled out of report text, before the user confirms it.
class ParsedResult {
  ParsedResult({
    required this.testKey,
    required this.testName,
    this.value,
    this.valueText,
    this.unit,
    this.refLow,
    this.refHigh,
    required this.sourceLine,
  });

  String testKey;
  String testName;
  double? value;
  String? valueText;
  String? unit;
  double? refLow;
  double? refHigh;

  /// The text line this came from, shown in the review screen.
  final String sourceLine;
}

class ParsedReport {
  ParsedReport(this.date, this.results, this.lines);
  final DateTime? date;
  final List<ParsedResult> results;
  final List<String> lines;
}

/// Heuristic, offline extraction of lab values from report text.
///
/// It is deliberately conservative: the user always reviews results before saving,
/// so a missed line is cheaper than a wrong one.
class ReportParser {
  ReportParser({this.sex});

  /// Member's sex ('F'/'M'), used to pick between printed male/female ranges.
  final String? sex;

  static final List<(String, LabTest)> _aliases = [
    for (final t in labCatalog)
      for (final a in {t.name.toLowerCase(), ...t.aliases}) (a, t),
  ]..sort((a, b) => b.$1.length.compareTo(a.$1.length));

  // Thousands separators: 7,500 · 2,50,000 (South Asian grouping) · 250,000
  static const _num = r'(?:\d{1,3}(?:,\d{2})*,\d{3}|\d+(?:[.,]\d+)?|\.\d+)';
  static final _numRe = RegExp('(?<![\\w.])([<>≤≥]=?\\s*)?($_num)');
  static final _rangeRe = RegExp('($_num)\\s*(?:-|–|—|to)\\s*($_num)');
  static final _upperRe = RegExp('(?:<|≤|less than|up ?to|below)\\s*($_num)');
  static final _lowerRe = RegExp('(?:>|≥|more than|above|greater than)\\s*($_num)');
  static final _exponentRe = RegExp(r'(?:[x×*]\s*)?10\s*(?:\^|e)?\s*[0-9³⁶⁹¹²]+(?=\s*/)', caseSensitive: false);
  static final _ordinalRe = RegExp(r'\b\d+(?:st|nd|rd|th)\b');
  static final _leadingJunk = RegExp(r'^[\s\d.)\-*•:|]+(?=[a-z])');

  ParsedReport parse(List<String> rawLines) {
    final lines = rawLines.map((l) => l.replaceAll(' ', ' ').trim()).where((l) => l.isNotEmpty).toList();
    final results = <ParsedResult>[];
    final seen = <String>{};

    for (var i = 0; i < lines.length; i++) {
      final r = _parseLine(lines[i], i + 1 < lines.length ? lines[i + 1] : null);
      if (r == null || seen.contains(r.testKey)) continue;
      seen.add(r.testKey);
      results.add(r);
    }
    return ParsedReport(findReportDate(lines), results, lines);
  }

  /// Interprets one table row given as separate printed strings (as an AI
  /// reader returns them), applying the same catalog matching, number parsing
  /// and unit conversion as [parse]. Returns null if [valuePrinted] is empty.
  ParsedResult? fromFields({
    required String name,
    required String valuePrinted,
    String? unit,
    String? range,
    required String sourceLine,
  }) {
    final printed = asciiDigits(valuePrinted).trim();
    if (printed.isEmpty) return null;
    final test = matchTest(name);
    final numeric = RegExp('^[<>≤≥]?=?\\s*($_num)\\s*[*a-z]{0,2}\$', caseSensitive: false).firstMatch(printed);
    final value = numeric == null ? null : _toDouble(numeric.group(1)!);
    if (value == null) {
      return ParsedResult(
        testKey: test?.key ?? customKey(name),
        testName: test?.name ?? name,
        valueText: printed,
        unit: unit,
        sourceLine: sourceLine,
      );
    }
    var (low, high) = _range(asciiDigits(range ?? '').toLowerCase());
    final factor = test?.factorFor(value, (unit ?? '').toLowerCase()) ?? 1;
    return ParsedResult(
      testKey: test?.key ?? customKey(name),
      testName: test?.name ?? name,
      value: _round(value * factor),
      unit: test?.unit ?? unit,
      refLow: low == null ? null : _round(low * factor),
      refHigh: high == null ? null : _round(high * factor),
      sourceLine: sourceLine,
    );
  }

  /// Catalog test for a printed test name, using the rules of [parse].
  static LabTest? matchTest(String printedName) {
    final name = printedName.trim();
    final exact = findTest(name) ?? findTest(name.replaceAll(RegExp(r'\s*\([^)]*\)'), ''));
    if (exact != null) return exact;
    final lower = name.toLowerCase();
    final text = lower.replaceFirst(_leadingJunk, '');
    for (final (alias, test) in _aliases) {
      if (!text.startsWith(alias)) continue;
      final after = text.substring(alias.length);
      if (after.isNotEmpty && RegExp(r'^[a-z0-9]').hasMatch(after) && !alias.endsWith('%')) continue;
      if (lower.contains('ratio') && !alias.contains('ratio')) return null;
      return test;
    }
    return null;
  }

  ParsedResult? _parseLine(String line, String? nextLine) {
    final lower = line.toLowerCase();
    final candidates = {lower, lower.replaceFirst(_leadingJunk, '')};

    for (final text in candidates) {
      for (final (alias, test) in _aliases) {
        if (!text.startsWith(alias)) continue;
        final after = text.substring(alias.length);
        // Whole-word match: "mch" must not match "mchc", "hb" must not match "hba1c".
        if (after.isNotEmpty && RegExp(r'^[a-z0-9]').hasMatch(after) && !alias.endsWith('%')) continue;
        // "Total Cholesterol/HDL ratio" is not total cholesterol.
        if (lower.contains('ratio') && !alias.contains('ratio')) return null;
        return _extract(test, after, line, nextLine);
      }
    }
    return _customLine(line);
  }

  ParsedResult? _extract(LabTest test, String rest, String line, String? nextLine) {
    rest = _clean(rest.replaceFirst(RegExp(r'^\s*(\([^)]*\)\s*)+'), ' '));
    var match = _numRe.firstMatch(rest);
    // OCR sometimes puts the value on the following row.
    if (match == null && nextLine != null) {
      final next = _clean(nextLine.toLowerCase());
      final m = _numRe.firstMatch(next);
      if (m != null && m.start < 3) {
        rest = next;
        match = m;
      }
    }
    if (match == null) {
      final word = RegExp(r'\b(negative|positive|nil|trace|absent|present|reactive|non-reactive)\b').firstMatch(rest);
      if (word == null) return null;
      return ParsedResult(
        testKey: test.key,
        testName: test.name,
        valueText: _titleCase(word.group(1)!),
        sourceLine: line,
      );
    }

    final value = _toDouble(match.group(2)!);
    if (value == null) return null;
    final afterValue = rest.substring(match.end);
    final unitText = RegExp(r'^[^\d]*').firstMatch(afterValue)!.group(0)!;

    var (low, high) = _range(afterValue);
    final factor = test.factorFor(value, '$unitText ${line.toLowerCase()}');

    return ParsedResult(
      testKey: test.key,
      testName: test.name,
      value: _round(value * factor),
      unit: test.unit,
      refLow: low == null ? null : _round(low * factor),
      refHigh: high == null ? null : _round(high * factor),
      sourceLine: line,
    );
  }

  /// Rows that look like "Name  value  unit  low - high" for tests not in the catalog.
  ParsedResult? _customLine(String line) {
    final m = RegExp(
      r'^([A-Za-z][A-Za-z .()/%-]{2,40}?)\s{1,}(' +
          _num +
          r')\s*([A-Za-zµ/%^0-9.]*)\s+(' +
          _num +
          r')\s*[-–]\s*(' +
          _num +
          r')\s*([A-Za-zµ/%^.]*)\s*$',
    ).firstMatch(line.trim());
    if (m == null) return null;
    final name = m.group(1)!.trim();
    if (RegExp(r'\b(date|age|page|id|phone|ref|no|year|time)\b', caseSensitive: false).hasMatch(name)) return null;
    if (RegExp('[a-z]', caseSensitive: false).allMatches(name).length < 3) return null;
    final unit = [m.group(3), m.group(6)].firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null);
    return ParsedResult(
      testKey: customKey(name),
      testName: name,
      value: _toDouble(m.group(2)!),
      unit: unit,
      refLow: _toDouble(m.group(4)!),
      refHigh: _toDouble(m.group(5)!),
      sourceLine: line,
    );
  }

  (double?, double?) _range(String text) {
    final ranges = _rangeRe.allMatches(text).toList();
    if (ranges.isNotEmpty) {
      var pick = ranges.first;
      // "M: 13 - 17  F: 12 - 15" — choose the one for this member.
      if (ranges.length > 1 && sex != null) {
        final label = sex == 'F' ? RegExp(r'(f|female|women)\s*[:\-]?\s*$') : RegExp(r'(m|male|men)\s*[:\-]?\s*$');
        for (final r in ranges) {
          if (label.hasMatch(text.substring(0, r.start))) pick = r;
        }
      }
      return (_toDouble(pick.group(1)!), _toDouble(pick.group(2)!));
    }
    final up = _upperRe.firstMatch(text);
    if (up != null) return (null, _toDouble(up.group(1)!));
    final lo = _lowerRe.firstMatch(text);
    if (lo != null) return (_toDouble(lo.group(1)!), null);
    return (null, null);
  }

  static String _clean(String s) => s.replaceAll(_exponentRe, ' ').replaceAll(_ordinalRe, ' ');

  static double? _toDouble(String s) {
    s = s.trim();
    if (RegExp(r'^\d{1,3}(?:,\d{2})*,\d{3}$').hasMatch(s)) {
      s = s.replaceAll(',', '');
    } else {
      s = s.replaceAll(',', '.'); // decimal comma, e.g. 11,2
    }
    return double.tryParse(s);
  }

  static double _round(double v) => double.parse(v.toStringAsPrecision(4));

  static String _titleCase(String s) => s[0].toUpperCase() + s.substring(1);
}

// ---- Dates

const _months = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Finds the most likely report date: a date on a line mentioning collection or
/// report, else the latest plausible date that isn't a date of birth.
DateTime? findReportDate(List<String> lines) {
  final today = DateTime.now();
  DateTime? keyed;
  final all = <DateTime>[];
  for (final line in lines) {
    final lower = line.toLowerCase();
    if (RegExp(r'\b(dob|d\.o\.b|birth)\b').hasMatch(lower)) continue;
    for (final d in parseDates(lower)) {
      if (d.isAfter(today) || d.year < 1950) continue;
      all.add(d);
      if (keyed == null && RegExp(r'collect|sample|report|receiv|date').hasMatch(lower)) keyed = d;
    }
  }
  if (keyed != null) return keyed;
  if (all.isEmpty) return null;
  all.sort();
  return all.last;
}

List<DateTime> parseDates(String text) {
  final out = <DateTime>[];
  DateTime? make(int y, int m, int d) {
    if (y < 100) y += 2000;
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    final date = DateTime(y, m, d);
    return date.month == m ? date : null;
  }

  for (final m in RegExp(r'\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b').allMatches(text)) {
    final d = make(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
    if (d != null) out.add(d);
  }
  for (final m in RegExp(r'\b(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})\b').allMatches(text)) {
    var a = int.parse(m[1]!), b = int.parse(m[2]!);
    // Day-first unless that's impossible.
    if (b > 12 && a <= 12) (a, b) = (b, a);
    final d = make(int.parse(m[3]!), b, a);
    if (d != null) out.add(d);
  }
  for (final m in RegExp(
    r'\b(\d{1,2})(?:st|nd|rd|th)?[\s\-/.,]*([a-z]{3})[a-z]*[\s\-/.,]*(\d{4}|\d{2})\b',
  ).allMatches(text)) {
    final month = _months[m[2]!];
    if (month == null) continue;
    final d = make(int.parse(m[3]!), month, int.parse(m[1]!));
    if (d != null) out.add(d);
  }
  for (final m in RegExp(
    r'\b([a-z]{3})[a-z]*[\s\-/.]+(\d{1,2})(?:st|nd|rd|th)?,?[\s\-/.]+(\d{4})\b',
  ).allMatches(text)) {
    final month = _months[m[1]!];
    if (month == null) continue;
    final d = make(int.parse(m[3]!), month, int.parse(m[2]!));
    if (d != null) out.add(d);
  }
  return out;
}
