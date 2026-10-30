import 'package:flutter_test/flutter_test.dart';
import 'package:medi_archive/data/models.dart';
import 'package:medi_archive/services/csv_service.dart';

void main() {
  group('Medication schedule', () {
    final course = Medication(
      memberId: 'm',
      name: 'Amoxicillin',
      times: [8 * 60, 20 * 60],
      startDate: DateTime(2026, 3, 1),
      days: 5,
    );

    test('course end and totals', () {
      expect(course.endDate, DateTime(2026, 3, 5));
      expect(course.totalDoses, 10);
      expect(course.dayNumber(DateTime(2026, 3, 3, 15)), 3);
      expect(course.isActiveOn(DateTime(2026, 3, 5)), isTrue);
      expect(course.isFinishedOn(DateTime(2026, 3, 6)), isTrue);
      expect(course.isActiveOn(DateTime(2026, 2, 28)), isFalse);
    });

    test('slots stop at the end of the course', () {
      final slots = course.slotsBetween(DateTime(2026, 3, 4, 9), DateTime(2026, 3, 20)).toList();
      expect(slots, [
        DateTime(2026, 3, 4, 20),
        DateTime(2026, 3, 5, 8),
        DateTime(2026, 3, 5, 20),
      ]);
    });

    test('ongoing medicine has no end', () {
      final thyroid = Medication(memberId: 'm', name: 'Levothyroxine', times: [7 * 60], startDate: DateTime(2025, 1, 1));
      expect(thyroid.endDate, isNull);
      expect(thyroid.slotsBetween(DateTime(2026, 1, 1), DateTime(2026, 1, 10, 23)).length, 10);
    });

    test('round-trips through a database row', () {
      final back = Medication.fromMap(course.toMap());
      expect(back.times, course.times);
      expect(back.days, 5);
      expect(DoseLog.slotKey(DateTime(2026, 3, 1, 8, 5)), '2026-03-01T08:05');
    });
  });

  group('CSV import', () {
    final member = Member(name: 'Nadia', sex: 'F', colorValue: 0);

    test('wide format: one row per date, one column per test', () {
      final r = CsvService.parse(
        'Date,Hemoglobin,WBC,Platelets\n'
        '2025-01-10,11.2,7500,250000\n'
        '2025-02-10,11.9,6.8,310\n',
        member,
      );
      expect(r.reports.length, 2);
      final jan = r.reports.first.$2;
      expect(jan.firstWhere((x) => x.testKey == 'wbc').value, 7.5);
      expect(jan.firstWhere((x) => x.testKey == 'platelets').value, 250);
      expect(jan.firstWhere((x) => x.testKey == 'hemoglobin').refLow, 12.0, reason: 'female default range');
    });

    test('long format with ranges, and app export re-imports', () {
      final r = CsvService.parse(
        'date,test,value,unit,reference range\n'
        '12/03/2025,Hb,10.5,g/dL,12 - 15.5\n'
        '12/03/2025,ESR,30,mm/hr,0-20\n',
        member,
      );
      expect(r.reports.single.$2.length, 2);
      final hb = r.reports.single.$2.first;
      expect(hb.testKey, 'hemoglobin');
      expect(hb.flag, ResultFlag.low);

      final exported = CsvService.export([member], [r.reports.single.$1], r.reports.single.$2);
      final again = CsvService.parse(exported, member);
      expect(again.resultCount, 2);
      expect(again.reports.single.$2.first.value, 10.5);
    });

    test('requires a date column', () {
      expect(() => CsvService.parse('test,value\nHb,11\n', member), throwsFormatException);
    });
  });
}
