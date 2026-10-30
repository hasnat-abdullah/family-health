import 'package:flutter_test/flutter_test.dart';
import 'package:family_health/services/report_parser.dart';

void main() {
  ParsedResult? find(ParsedReport r, String key) =>
      r.results.where((x) => x.testKey == key).firstOrNull;

  test('parses a typical CBC table with per-µL counts', () {
    final report = ReportParser(sex: 'F').parse([
      'Popular Diagnostic Centre',
      'Patient: Jane Doe        DOB: 12/04/1990',
      'Sample Collected: 14-Mar-2025 09:12',
      'Test   Result   Unit   Reference Range',
      'Haemoglobin (Hb)   11.2   g/dL   12.0 - 15.5',
      'Total WBC Count   7,500   /cumm   4,000 - 11,000',
      'Neutrophils   62   %   40 - 75',
      'Lymphocytes   30   %   20 - 45',
      'Platelet Count   2,50,000   /cumm   1,50,000 - 4,50,000',
      'MCV   78.4   fL   80 - 100',
      'MCH   26   pg   27 - 33',
      'MCHC   33.1   g/dL   32 - 36',
      'RBC Count   4.10   million/cumm   M: 4.5 - 5.9  F: 4.0 - 5.2',
      'ESR   28   mm in 1st hour   0 - 20',
    ]);

    expect(report.date, DateTime(2025, 3, 14));
    final hb = find(report, 'hemoglobin')!;
    expect(hb.value, 11.2);
    expect(hb.refLow, 12.0);
    expect(hb.refHigh, 15.5);

    final wbc = find(report, 'wbc')!;
    expect(wbc.value, 7.5);
    expect(wbc.refLow, 4.0);
    expect(wbc.refHigh, 11.0);

    final plt = find(report, 'platelets')!;
    expect(plt.value, 250);
    expect(plt.refHigh, 450);

    expect(find(report, 'mch')!.value, 26);
    expect(find(report, 'mchc')!.value, 33.1);
    expect(find(report, 'neutrophils')!.value, 62);

    final rbc = find(report, 'rbc')!;
    expect(rbc.value, 4.1);
    expect(rbc.refLow, 4.0, reason: 'female range picked');

    final esr = find(report, 'esr')!;
    expect(esr.value, 28);
    expect(esr.refHigh, 20);
  });

  test('handles exponent units, serial numbers and mg/dL glucose', () {
    final report = ReportParser().parse([
      '1. WBC 6.8 x10^3/uL 4.0-11.0',
      '2. Platelets 310 10^3/µL 150 - 450',
      'Fasting Blood Sugar 99 mg/dL 70 - 100',
      'HbA1c 5.9 % < 5.7',
      'Total Cholesterol/HDL Ratio 4.1',
      'Total Cholesterol 190 mg/dL',
    ]);
    expect(find(report, 'wbc')!.value, 6.8);
    expect(find(report, 'platelets')!.value, 310);
    final fbs = find(report, 'glucose_fasting')!;
    expect(fbs.value, closeTo(5.5, 0.01));
    expect(fbs.refHigh, closeTo(5.556, 0.01));
    expect(find(report, 'hba1c')!.refHigh, 5.7);
    expect(find(report, 'cholesterol_total')!.value, 190);
  });

  test('captures unknown tests that have a printed range', () {
    final report = ReportParser().parse(['Reticulocyte Count  1.2  %  0.5 - 2.5']);
    final r = report.results.single;
    expect(r.testKey, 'custom:reticulocyte_count');
    expect(r.value, 1.2);
    expect(r.refHigh, 2.5);
  });

  test('date formats', () {
    expect(parseDates('report date: 2024-11-05'), [DateTime(2024, 11, 5)]);
    expect(parseDates('05/11/2024'), [DateTime(2024, 11, 5)]);
    expect(parseDates('11/25/2024'), [DateTime(2024, 11, 25)]);
    expect(parseDates('march 3, 2024'), [DateTime(2024, 3, 3)]);
  });
}
