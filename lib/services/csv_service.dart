import 'package:csv/csv.dart';

import '../data/lab_catalog.dart';
import '../data/models.dart';
import 'report_parser.dart';

class CsvImport {
  CsvImport(this.reports, this.skippedRows);
  final List<(Report, List<TestResult>)> reports;
  final int skippedRows;

  int get resultCount => reports.fold(0, (n, r) => n + r.$2.length);
}

/// CSV in two shapes:
///  * long: `date,test,value,unit,ref_low,ref_high[,lab,report]` — one row per result
///  * wide: `date,Hemoglobin,WBC,Platelets,…` — one row per report, one column per test
class CsvService {
  static final _codec = Csv(lineDelimiter: '\n');

  static const _dateCols = ['date', 'report date', 'test date', 'collection date', 'sample date'];
  static const _testCols = ['test', 'test name', 'name', 'parameter', 'investigation'];
  static const _valueCols = ['value', 'result', 'results', 'reading'];
  static const _unitCols = ['unit', 'units'];
  static const _lowCols = ['ref_low', 'low', 'min', 'reference low', 'range low'];
  static const _highCols = ['ref_high', 'high', 'max', 'reference high', 'range high'];
  static const _rangeCols = ['range', 'reference range', 'ref range', 'normal range', 'reference'];
  static const _labCols = ['lab', 'laboratory', 'hospital'];
  static const _titleCols = ['report', 'title', 'report title', 'panel'];
  static const _memberCols = ['member', 'person', 'patient'];

  static String export(List<Member> members, List<Report> reports, List<TestResult> results) {
    final memberName = {for (final m in members) m.id: m.name};
    final reportById = {for (final r in reports) r.id: r};
    final rows = <List<Object?>>[
      ['member', 'date', 'test', 'value', 'unit', 'ref_low', 'ref_high', 'lab', 'report'],
      for (final r in results)
        [
          memberName[r.memberId] ?? '',
          dateToDb(r.date),
          r.testName,
          r.value ?? r.valueText ?? '',
          r.unit ?? '',
          r.refLow ?? '',
          r.refHigh ?? '',
          reportById[r.reportId]?.lab ?? '',
          reportById[r.reportId]?.title ?? '',
        ],
    ];
    return _codec.encode(rows);
  }

  /// Parses [text] into reports for [member]. Rows on the same date (and report
  /// title, if given) become one report.
  static CsvImport parse(String text, Member member) {
    final rows = _codec.decode(text.replaceFirst('﻿', '')).where((r) => r.any((c) => '$c'.trim().isNotEmpty)).toList();
    if (rows.length < 2) return CsvImport(const [], 0);
    final header = rows.first.map((c) => '$c'.trim().toLowerCase()).toList();
    int col(List<String> names) => header.indexWhere(names.contains);

    final dateCol = col(_dateCols);
    if (dateCol < 0) throw const FormatException('The CSV needs a "date" column.');

    final grouped = <String, (Report, List<TestResult>)>{};
    var skipped = 0;

    (Report, List<TestResult>) group(DateTime date, String? title, String? lab) {
      final key = '${dateToDb(date)}|${title ?? ''}';
      return grouped.putIfAbsent(
        key,
        () => (Report(memberId: member.id, title: title ?? 'Lab results', date: date, lab: lab), <TestResult>[]),
      );
    }

    String? cell(List<dynamic> row, int i) {
      if (i < 0 || i >= row.length) return null;
      final v = '${row[i]}'.trim();
      return v.isEmpty ? null : v;
    }

    final testCol = col(_testCols);
    final valueCol = col(_valueCols);
    final isLong = testCol >= 0 && valueCol >= 0;

    if (isLong) {
      final memberCol = col(_memberCols);
      for (final row in rows.skip(1)) {
        final date = _date(cell(row, dateCol));
        final name = cell(row, testCol);
        final raw = cell(row, valueCol);
        final rowMember = cell(row, memberCol);
        if (rowMember != null && rowMember.toLowerCase() != member.name.toLowerCase()) continue;
        if (date == null || name == null || raw == null) {
          skipped++;
          continue;
        }
        var low = _double(cell(row, col(_lowCols)));
        var high = _double(cell(row, col(_highCols)));
        final range = cell(row, col(_rangeCols));
        if (low == null && high == null && range != null) {
          final m = RegExp(r'([\d.]+)\s*[-–]\s*([\d.]+)').firstMatch(range);
          if (m != null) (low, high) = (double.tryParse(m[1]!), double.tryParse(m[2]!));
        }
        final g = group(date, cell(row, col(_titleCols)), cell(row, col(_labCols)));
        g.$2.add(_result(g.$1, member, name, raw, cell(row, col(_unitCols)), low, high));
      }
    } else {
      final known = {dateCol, col(_labCols), col(_titleCols), col(_memberCols)};
      for (final row in rows.skip(1)) {
        final date = _date(cell(row, dateCol));
        if (date == null) {
          skipped++;
          continue;
        }
        final g = group(date, cell(row, col(_titleCols)), cell(row, col(_labCols)));
        for (var i = 0; i < header.length; i++) {
          final raw = cell(row, i);
          if (known.contains(i) || raw == null) continue;
          g.$2.add(_result(g.$1, member, '${rows.first[i]}'.trim(), raw, null, null, null));
        }
      }
    }

    final reports = grouped.values.where((g) => g.$2.isNotEmpty).toList()
      ..sort((a, b) => a.$1.date.compareTo(b.$1.date));
    return CsvImport(reports, skipped);
  }

  static TestResult _result(
    Report report,
    Member member,
    String name,
    String raw,
    String? unit,
    double? low,
    double? high,
  ) {
    final test = findTest(name);
    final value = _double(raw);
    final factor = (test != null && value != null) ? test.factorFor(value, unit ?? '') : 1.0;
    final range = test?.rangeFor(member.sex);
    final scaledLow = low == null ? null : low * factor;
    final scaledHigh = high == null ? null : high * factor;
    return TestResult(
      reportId: report.id,
      memberId: member.id,
      testKey: test?.key ?? customKey(name),
      testName: test?.name ?? name,
      value: value == null ? null : value * factor,
      valueText: value == null ? raw : null,
      unit: test?.unit ?? unit,
      refLow: scaledLow ?? (scaledHigh == null ? range?.low : null),
      refHigh: scaledHigh ?? (scaledLow == null ? range?.high : null),
      date: report.date,
    );
  }

  static double? _double(String? s) => s == null ? null : double.tryParse(s.replaceAll(',', ''));

  static DateTime? _date(String? s) {
    if (s == null) return null;
    final iso = DateTime.tryParse(s);
    if (iso != null) return DateTime(iso.year, iso.month, iso.day);
    final found = parseDates(s.toLowerCase());
    return found.isEmpty ? null : found.first;
  }
}
