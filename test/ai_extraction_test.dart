import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:family_health/data/models.dart';
import 'package:family_health/services/ai/ai_client.dart';
import 'package:family_health/services/ai/extraction.dart';
import 'package:family_health/services/ai/extraction_prompt.dart';
import 'package:family_health/services/medicine_schedule.dart';

Map<String, Object?> row(String name, String? value, {String? unit, String? range, String? flag, bool legible = true}) => {
  'test_name_printed': name,
  'value_printed': value,
  'unit_printed': unit,
  'reference_range_printed': range,
  'flag_printed': flag,
  'legible': legible,
  'source_text': '$name $value',
};

Map<String, Object?> med(String name, {String? strength, String? schedule, String? duration, bool legible = true}) => {
  'name_printed': name,
  'strength_printed': strength,
  'schedule_printed': schedule,
  'duration_printed': duration,
  'instructions_printed': null,
  'legible': legible,
  'source_text': name,
};

AiDocument doc({
  String type = 'lab',
  bool medical = true,
  String? date,
  String? iso,
  String? patient,
  String? age,
  String? sex,
  List<String> others = const [],
  String? doctor,
  List<Map<String, Object?>> rows = const [],
  List<Map<String, Object?>> meds = const [],
  int? followDays,
}) => AiDocument.parse(jsonEncode({
  'is_medical_document': medical,
  'document_type': type,
  'title': 'CBC',
  'report_date_printed': date,
  'report_date': iso,
  'patient': {'name_printed': patient, 'age_printed': age, 'sex_printed': sex},
  'other_patients': others,
  'facility': null,
  'doctor': {'name_printed': doctor, 'specialty_printed': null, 'hospital_printed': null, 'phone_printed': null},
  'lab_results': rows,
  'medicines': meds,
  'notes_printed': null,
  'follow_up_printed': null,
  'follow_up_date': null,
  'follow_up_days': followDays,
}));

const cbcLines = [
  'Popular Diagnostic Centre',
  'Patient: Mrs Nadia Rahman   Age: 33 Y  Sex: Female',
  'Report date: 12/03/2026',
  'Test Result Unit Reference',
  'Haemoglobin 11.2 g/dL 12.0 - 15.5',
  'WBC 7,500 /cumm 4,000 - 11,000',
  'Platelet Count 2,50,000 /cumm 1,50,000 - 4,50,000',
];

void main() {
  final nadia = Member(name: 'Nadia Rahman', relation: 'Spouse', sex: 'F', colorValue: 0, birthDate: DateTime(1993, 5, 2));
  final imran = Member(name: 'Imran', relation: 'Self', sex: 'M', colorValue: 0);
  final family = [nadia, imran];
  final today = DateTime(2026, 10, 30);
  ExtractionChecker checker({Member? member, Map<String, double> history = const {}, List<Doctor> doctors = const []}) =>
      ExtractionChecker(member: member ?? nadia, history: history, doctors: doctors, today: today);
  DraftResult find(ExtractionDraft d, String key) => d.results.firstWhere((r) => r.parsed.testKey == key);

  group('values are interpreted by code, not the model', () {
    test('printed strings become the same numbers as on-device reading', () {
      final d = checker().check(doc(rows: [
        row('Haemoglobin', '11.2', unit: 'g/dL', range: '12.0 - 15.5', flag: 'L'),
        row('WBC', '7,500', unit: '/cumm', range: '4,000 - 11,000'),
        row('Platelet Count', '2,50,000', unit: '/cumm', range: '1,50,000 - 4,50,000'),
      ]), cbcLines);
      final hb = find(d, 'hemoglobin');
      expect((hb.parsed.value, hb.parsed.refLow, hb.parsed.refHigh, hb.check), (11.2, 12, 15.5, Check.confirmed));
      expect(find(d, 'wbc').parsed.value, 7.5);
      expect(find(d, 'wbc').parsed.refHigh, 11);
      expect(find(d, 'platelets').parsed.value, 250);
      expect(find(d, 'platelets').check, Check.confirmed);
      expect(d.toReview, 0);
    });

    test('Bengali digits and text results', () {
      final d = checker().check(doc(rows: [row('Hemoglobin', '১১.২', unit: 'g/dL'), row('Urine Sugar', 'Negative')]), cbcLines);
      expect(find(d, 'hemoglobin').parsed.value, 11.2);
      final urine = d.results.firstWhere((r) => r.parsed.testName.contains('Urine'));
      expect((urine.parsed.value, urine.parsed.valueText), (null, 'Negative'));
    });

    test('a sex-specific range picks the right side', () {
      final d = checker().check(doc(rows: [row('Hemoglobin', '11.2', range: 'M: 13 - 17  F: 12 - 15.5')]), cbcLines);
      expect(find(d, 'hemoglobin').parsed.refLow, 12);
    });

    test('an inverted range is dropped rather than flagging falsely', () {
      final d = checker().check(doc(rows: [row('Hemoglobin', '11.2', range: '15.5 - 12.0')]), cbcLines);
      expect(find(d, 'hemoglobin').parsed.refLow, isNull);
      expect(find(d, 'hemoglobin').note, contains('range'));
    });
  });

  group('hallucination', () {
    test('a value not on the page is flagged', () {
      final d = checker().check(doc(rows: [row('Hemoglobin', '13.8')]), cbcLines);
      final hb = find(d, 'hemoglobin');
      expect(hb.check, isNot(Check.confirmed));
      expect(hb.check.needsReview, isTrue);
      expect(hb.alternative, 11.2);
      expect(d.toReview, greaterThan(0));
    });

    test('a whole invented test is flagged', () {
      final d = checker().check(doc(rows: [row('Ferritin', '42', unit: 'ng/mL')]), cbcLines);
      expect(find(d, 'ferritin').check, Check.notFound);
    });

    test('a value borrowed from another row is not "confirmed"', () {
      // 12.0 is on the page, but as Haemoglobin's lower limit.
      final d = checker().check(doc(rows: [row('MCV', '12.0')]), cbcLines);
      expect(find(d, 'mcv').check, Check.onPage);
    });

    test('swapped values between rows are caught', () {
      final d = checker().check(doc(rows: [row('Haemoglobin', '7,500', unit: 'g/dL'), row('WBC', '11.2', unit: '/cumm')]), cbcLines);
      expect(find(d, 'hemoglobin').check, Check.conflict);
      expect(find(d, 'wbc').check, Check.conflict);
    });

    test('a slipped decimal is caught against history even with no local text', () {
      final d = checker(history: {'creatinine': 0.9}).check(doc(rows: [row('Creatinine', '9.0')]), const []);
      expect(find(d, 'creatinine').note, contains('decimal'));
    });

    test('a printed flag that contradicts the value is caught', () {
      final d = checker().check(doc(rows: [row('Haemoglobin', '11.2', range: '12.0 - 15.5', flag: 'H')]), cbcLines);
      expect(find(d, 'hemoglobin').check.needsReview, isTrue);
      expect(find(d, 'hemoglobin').note, contains('marks this high'));
    });

    test('an unreadable value stays empty', () {
      final d = checker().check(doc(rows: [row('Bilirubin', '1.?', legible: false)]), cbcLines);
      final r = d.results.firstWhere((r) => r.check == Check.unreadable);
      expect((r.check, r.parsed.value, r.parsed.valueText), (Check.unreadable, null, null));
    });

    test('with no local text nothing is claimed as confirmed', () {
      final d = checker().check(doc(rows: [row('Hemoglobin', '11.2')], meds: [med('Napa', schedule: '1+0+1', duration: '5 days')]), const []);
      expect(find(d, 'hemoglobin').check, Check.uncheckable);
      expect(d.medicines.single.check, Check.uncheckable);
      expect(d.toReview, 2);
    });

    test('mostly unverifiable pages warn as a whole', () {
      final d = checker().check(doc(rows: [row('Ferritin', '42'), row('TSH', '3.1')]), cbcLines);
      expect(d.issues.join(), contains('handwritten'));
    });

    test('a non-medical file yields no data', () {
      final d = checker().check(doc(medical: false, rows: [row('Hemoglobin', '11.2')]), cbcLines);
      expect(d.results, isEmpty);
      expect(d.issues.single, contains("doesn't look like a medical"));
    });

    test('results the AI missed are kept from the on-device reader', () {
      final d = checker().check(doc(rows: [row('Haemoglobin', '11.2')]), cbcLines);
      expect(find(d, 'wbc').check, Check.localOnly);
      expect(find(d, 'wbc').parsed.value, 7.5);
    });
  });

  group('mixing', () {
    test('percent and absolute of one test never share a trend', () {
      final d = checker().check(doc(rows: [row('Neutrophils', '62', unit: '%'), row('Neutrophils Absolute', '4650', unit: '/cumm')]), const []);
      expect(d.results.map((r) => r.parsed.testKey).toSet(), hasLength(2));
    });

    test('an exact repeat of a row is dropped', () {
      final d = checker().check(doc(rows: [row('Hemoglobin', '11.2'), row('Haemoglobin', '11.2')]), cbcLines);
      expect(d.results.where((r) => r.parsed.testKey == 'hemoglobin'), hasLength(1));
    });

    test('the patient is matched to the family on the device', () {
      expect(matchPatient(doc(patient: 'Mrs. Nadia Rahman'), family, nadia).status, PatientStatus.matchesCurrent);
      final other = matchPatient(doc(patient: 'Md. Imran'), family, nadia);
      expect((other.status, other.member), (PatientStatus.matchesOther, imran));
      expect(matchPatient(doc(patient: 'Nadya Rahman'), family, imran).member, nadia, reason: 'one misread letter');
      expect(matchPatient(doc(patient: 'Karim Uddin'), family, nadia).status, PatientStatus.noMatch);
      expect(matchPatient(doc(), family, nadia).status, PatientStatus.notPrinted);
    });

    test('a shared surname is not a match', () {
      expect(matchPatient(doc(patient: 'Karim Rahman'), family, nadia).status, PatientStatus.noMatch);
    });

    test('a name fitting two members decides nothing', () {
      final twins = [Member(name: 'Sara Khan', colorValue: 0), Member(name: 'Sara Ali', colorValue: 0)];
      expect(matchPatient(doc(patient: 'Sara'), twins, null).status, PatientStatus.noMatch);
    });

    test('wrong sex, wrong age and second patients warn', () {
      final d = checker().check(doc(patient: 'A Rahman', sex: 'Male', age: '61 Y', others: ['Karim Uddin'], date: '12/03/2026'), cbcLines);
      final all = d.issues.join(' ');
      expect(all, contains('differs from Nadia'));
      expect(all, contains('age 61'));
      expect(all, contains('Karim Uddin'));
    });

    test('a matching age is quiet, and baby ages are not compared', () {
      expect(checker().check(doc(sex: 'F', age: '32 years'), cbcLines).issues, isEmpty);
      expect(checker().check(doc(age: '3 months'), cbcLines).issues, isEmpty);
    });
  });

  group('dates', () {
    test('ambiguous numeric dates are day-first, whatever the model said', () {
      final d = checker().check(doc(date: '03/04/2026', iso: '2026-03-04'), const []);
      expect(d.date, DateTime(2026, 4, 3));
    });

    test('a future date is rejected', () {
      final d = checker().check(doc(date: '12/03/2099'), const []);
      expect(d.date, isNull);
      expect(d.issues.single, contains('not possible'));
    });

    test('disagreement with the on-device date is raised', () {
      final d = checker().check(doc(date: '11/03/2026'), cbcLines);
      expect(d.issues.join(), contains('Check the date'));
    });

    test('follow-up counts from the document date', () {
      expect(checker().check(doc(date: '12/03/2026', followDays: 28), const []).followUp, DateTime(2026, 4, 9));
    });
  });

  group('doctors', () {
    final karim = Doctor(name: 'Dr. Abdul Karim', specialty: 'Haematology');
    test('titles and degrees are ignored', () {
      expect(matchDoctor('Prof. Dr. Abdul Karim, MBBS, FCPS', [karim]), karim.id);
      expect(matchDoctor('Dr. Abdul Karem', [karim]), karim.id);
      expect(matchDoctor('Dr. Rahima Karim', [karim]), isNull);
    });
    test('one shared word is not enough', () {
      expect(matchDoctor('Dr. Karim', [karim]), isNull);
    });
  });

  group('prescriptions', () {
    test('medicines get rule-based schedules', () {
      final d = checker().check(
        doc(type: 'prescription', meds: [
          med('Napa', strength: '500 mg', schedule: '১+০+১', duration: '৭ দিন'),
          med('Thyrox', schedule: '1+0+0', duration: 'চলবে'),
          med('Sergel', schedule: 'when needed'),
        ]),
        const ['Rx', 'Napa 500 mg 1+0+1', 'Thyrox 50 1+0+0', 'Sergel 20', 'x'],
      );
      final m = d.medicines;
      expect(m[0].times, [480, 1200]);
      expect((m[0].days, m[0].check), (7, Check.confirmed));
      expect(m[1].times, [480]);
      expect(m[1].ongoing, isTrue);
      expect((m[2].times, m[2].days), (null, null));
      expect(m[2].note, contains('dose times'));
    });

    test('an illegible or invented medicine is flagged', () {
      final d = checker().check(doc(meds: [med('Azithro', legible: false), med('Warfarin')]), const ['Napa 500', 'a', 'b', 'c']);
      expect(d.medicines[0].check, Check.unreadable);
      expect(d.medicines[1].check, Check.notFound);
    });
  });

  group('MedicineSchedule', () {
    test('times', () {
      for (final (text, want) in [
        ('1+0+1', [480, 1200]),
        ('1-1-1', [480, 840, 1200]),
        ('0 + 0 + 1', [1200]),
        ('১+১+১', [480, 840, 1200]),
        ('1/2+0+1/2', [480, 1200]),
        ('1+1+1+1', [480, 720, 960, 1200]),
        ('BD', [480, 1200]),
        ('TDS after meal', [480, 840, 1200]),
        ('at night', [1260]),
        ('রাতে', [1260]),
        ('once daily', [480]),
        ('0+0+0', <int>[]),
      ]) {
        expect(MedicineSchedule.parseTimes(text), want, reason: text);
      }
      expect(MedicineSchedule.parseTimes('as needed'), isNull);
      expect(MedicineSchedule.parseTimes(null), isNull);
    });

    test('durations', () {
      expect(MedicineSchedule.parseDuration('7 days').days, 7);
      expect(MedicineSchedule.parseDuration('২ সপ্তাহ').days, 14);
      expect(MedicineSchedule.parseDuration('1 month').days, 30);
      expect(MedicineSchedule.parseDuration('৩ মাস').days, 90);
      expect(MedicineSchedule.parseDuration('Cont.').ongoing, isTrue);
      expect(MedicineSchedule.parseDuration('চলবে').ongoing, isTrue);
      expect(MedicineSchedule.parseDuration('soon').days, isNull);
    });
  });

  group('AiReader', () {
    test('one bad reply is retried; two are refused and nothing is used', () async {
      final good = jsonEncode(extractionExample);
      final once = _Scripted(['not json', '```json\n$good\n```']);
      expect((await AiReader(once).read(images: const [], localLines: const ['text'])).title, 'CBC');
      expect(once.calls, 2);

      final never = _Scripted(['nope', '{"partial":true}']);
      await expectLater(
        AiReader(never).read(images: const [], localLines: const ['text']),
        throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiErrorKind.invalidResponse)),
      );
    });

    test('family data is never in the prompt', () async {
      final s = _Scripted([jsonEncode(extractionExample)]);
      await AiReader(s).read(images: const [], localLines: const ['Hb 11']);
      final sent = '${s.last!.system}${s.last!.prompt}';
      expect(sent, isNot(contains('Nadia')));
      expect(s.last!.prompt, contains('<document>'));
    });

    test('nothing to send is an error before any call', () async {
      final s = _Scripted(const []);
      await expectLater(AiReader(s).read(images: const [], localLines: const []), throwsA(isA<AiException>()));
      expect(s.calls, 0);
    });
  });

  test('the schema is valid for strict mode everywhere', () {
    void walk(Map<String, Object?> s) {
      if (s['type'] == 'object') {
        final props = s['properties'] as Map<String, Object?>;
        expect(s['additionalProperties'], false);
        expect((s['required'] as List).toSet(), props.keys.toSet());
        for (final v in props.values) {
          walk(v as Map<String, Object?>);
        }
      }
      if (s['items'] != null) walk(s['items'] as Map<String, Object?>);
    }

    walk(extractionSchema);
  });
}

final extractionExample = <String, Object?>{
  'is_medical_document': true,
  'document_type': 'lab',
  'title': 'CBC',
  'lab_results': <Object?>[],
  'medicines': <Object?>[],
};

class _Scripted implements AiBackend {
  _Scripted(this.replies);
  final List<String> replies;
  var calls = 0;
  AiRequest? last;

  @override
  Future<String> complete(AiRequest r, {AiCancelToken? cancel}) async {
    last = r;
    return replies[calls++];
  }

  @override
  Future<List<String>> listModels({AiCancelToken? cancel}) async => const [];
}
