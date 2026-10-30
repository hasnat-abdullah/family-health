import 'dart:math' as math;

import 'data/database.dart';
import 'data/models.dart';

/// Sample family for `--dart-define=DEMO=true` (stored in a separate demo database).
Future<void> seedDemo() async {
  final db = AppDb.instance;
  if ((await db.members()).isNotEmpty) return;
  final now = DateTime.now();
  final rnd = math.Random(7);

  final wife = Member(
    name: 'Nadia Rahman',
    relation: 'Spouse',
    sex: 'F',
    birthDate: DateTime(1994, 3, 11),
    bloodGroup: 'B+',
    colorValue: 0xffeb6834,
  );
  final me = Member(
    name: 'Imran',
    relation: 'Self',
    sex: 'M',
    birthDate: DateTime(1988, 6, 21),
    bloodGroup: 'O+',
    colorValue: 0xff2a78d6,
  );
  final son = Member(
    name: 'Zayan',
    relation: 'Son',
    sex: 'M',
    birthDate: DateTime(2020, 1, 15),
    colorValue: 0xff1baf7a,
  );
  for (final m in [wife, me, son]) {
    await db.saveMember(m);
  }

  TestResult r(Report rep, Member m, String key, String name, double v, String unit, double? lo, double? hi) =>
      TestResult(
        reportId: rep.id,
        memberId: m.id,
        testKey: key,
        testName: name,
        value: double.parse(v.toStringAsFixed(1)),
        unit: unit,
        refLow: lo,
        refHigh: hi,
        date: rep.date,
      );

  // Monthly CBC for 14 months: anaemia slowly improving on iron.
  for (var i = 13; i >= 0; i--) {
    final date = DateTime(now.year, now.month - i, 12);
    final rep = Report(memberId: wife.id, title: 'CBC', date: date, lab: 'City Diagnostic');
    final t = (13 - i) / 13;
    await db.saveReport(rep, [
      r(
        rep,
        wife,
        'hemoglobin',
        'Hemoglobin',
        10.2 + 1.6 * t + rnd.nextDouble() * 0.5 - (i == 0 ? 0.6 : 0),
        'g/dL',
        12,
        15.5,
      ),
      r(rep, wife, 'wbc', 'WBC (Total Count)', 6 + rnd.nextDouble() * 3, '×10⁹/L', 4, 11),
      r(rep, wife, 'platelets', 'Platelet Count', 210 + rnd.nextDouble() * 90, '×10⁹/L', 150, 450),
      r(rep, wife, 'mcv', 'MCV', 74 + 8 * t + rnd.nextDouble() * 2, 'fL', 80, 100),
      r(rep, wife, 'neutrophils', 'Neutrophils', 55 + rnd.nextDouble() * 15, '%', 40, 75),
      r(rep, wife, 'esr', 'ESR', 14 + rnd.nextDouble() * 10 + (i == 0 ? 6 : 0), 'mm/hr', 0, 20),
    ], const []);
  }

  for (var i = 3; i >= 0; i--) {
    final date = DateTime(now.year, now.month - i * 4, 3);
    final rep = Report(memberId: me.id, title: 'Lipid profile & HbA1c', date: date, lab: 'City General Hospital');
    await db.saveReport(rep, [
      r(rep, me, 'cholesterol_total', 'Total Cholesterol', 228 - i * -4 - (3 - i) * 9.0, 'mg/dL', null, 200),
      r(rep, me, 'ldl', 'LDL Cholesterol', 148 - (3 - i) * 11.0, 'mg/dL', null, 100),
      r(rep, me, 'hdl', 'HDL Cholesterol', 38 + (3 - i) * 1.5, 'mg/dL', 40, null),
      r(rep, me, 'hba1c', 'HbA1c', 5.9 - (3 - i) * 0.1, '%', null, 5.7),
    ], const []);
  }

  final karim = Doctor(
    name: 'Dr. Abdul Karim',
    specialty: 'Haematology',
    hospital: 'City General Hospital',
    phone: '+880 1700-000000',
  );
  await db.saveDoctor(karim);
  final rx = Report(
    memberId: wife.id,
    title: 'Haematology follow-up',
    date: now.subtract(const Duration(days: 5)),
    type: DocType.prescription,
    doctorId: karim.id,
    followUp: now.add(const Duration(days: 23)),
    notes: 'Continue iron. Repeat CBC in 4 weeks.',
  );
  await db.saveReport(rx, const [], const []);
  final iron = Medication(
    memberId: wife.id,
    reportId: rx.id,
    name: 'Ferrous sulfate',
    dose: '200 mg',
    times: [9 * 60, 21 * 60],
    startDate: rx.date,
    days: 30,
    instructions: 'after meal',
  );
  final vitc = Medication(
    memberId: wife.id,
    reportId: rx.id,
    name: 'Vitamin C',
    dose: '500 mg',
    times: [9 * 60],
    startDate: rx.date,
    days: 30,
  );
  final syrup = Medication(
    memberId: son.id,
    name: 'Paracetamol syrup',
    dose: '5 ml',
    times: [8 * 60, 14 * 60, 20 * 60],
    startDate: now.subtract(const Duration(days: 1)),
    days: 3,
  );
  for (final m in [iron, vitc, syrup]) {
    await db.saveMedication(m);
  }
  for (var d = 5; d >= 1; d--) {
    final day = DateTime(now.year, now.month, now.day - d);
    await db.setTaken(iron, DateTime(day.year, day.month, day.day, 9), true);
    await db.setTaken(iron, DateTime(day.year, day.month, day.day, 21), true);
    await db.setTaken(vitc, DateTime(day.year, day.month, day.day, 9), true);
  }
  await db.setTaken(iron, DateTime(now.year, now.month, now.day, 9), true);

  final vax = Report(
    memberId: son.id,
    title: 'Vaccination card',
    date: DateTime(2024, 3, 1),
    type: DocType.vaccination,
  );
  await db.saveReport(vax, const [], const []);
}
