// AI reading end to end, against a real HTTP server standing in for a local model.
//   flutter test integration_test/ai_flow_test.dart -d macos
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:family_health/data/database.dart';
import 'package:family_health/data/models.dart';
import 'package:family_health/data/storage.dart';
import 'package:family_health/main.dart';
import 'package:family_health/screens/doctors_screen.dart';
import 'package:family_health/security/app_lock.dart';
import 'package:family_health/services/ai/ai_config.dart';
import 'package:family_health/services/backup_service.dart';
import 'package:family_health/services/file_io.dart';

import 'harness.dart';

/// Answers like an OpenAI-compatible server; [reply] decides each response.
class FakeModelServer {
  late HttpServer _server;
  final requests = <Map<String, Object?>>[];
  late (int, Object) Function(Map<String, Object?> body) reply;

  String get url => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((r) async {
      final body = jsonDecode(await utf8.decodeStream(r)) as Map<String, Object?>;
      requests.add(body);
      final (status, out) = reply(body);
      r.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(out));
      await r.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

(int, Object) modelSays(Map<String, Object?> document) => (
  200,
  {
    'choices': [
      {
        'finish_reason': 'stop',
        'message': {'content': jsonEncode(document)},
      },
    ],
  },
);

Map<String, Object?> labRow(String name, String value, String unit, String range) => {
  'test_name_printed': name,
  'value_printed': value,
  'unit_printed': unit,
  'reference_range_printed': range,
  'flag_printed': null,
  'legible': true,
  'source_text': '$name $value',
};

Map<String, Object?> document({
  String type = 'lab',
  String? patient,
  String? doctor,
  List<Map<String, Object?>> rows = const [],
  List<Map<String, Object?>> medicines = const [],
  int? followDays,
}) => {
  'is_medical_document': true,
  'document_type': type,
  'title': type == 'lab' ? 'Complete Blood Count' : 'Fever consultation',
  'report_date_printed': null,
  'report_date': null,
  'patient': {'name_printed': patient, 'age_printed': null, 'sex_printed': null},
  'other_patients': <String>[],
  'facility': null,
  'doctor': {
    'name_printed': doctor,
    'specialty_printed': 'Medicine',
    'hospital_printed': 'City General Hospital',
    'phone_printed': null,
  },
  'lab_results': rows,
  'medicines': medicines,
  'notes_printed': null,
  'follow_up_printed': null,
  'follow_up_date': null,
  'follow_up_days': followDays,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a document goes from file to saved records, surviving failures on the way', (tester) async {
    addTearDown(resetHooks);
    AppLock.authenticator = FakeAuthenticator();
    final server = FakeModelServer();
    await server.start();
    addTearDown(server.stop);

    final storage = TestStorage('ai');
    await storage.wipe();
    await storage.boot();
    final db = AppDb.instance;
    final wife = Member(name: 'Nadia Rahman', sex: 'F', colorValue: 0xff2a78d6);
    final me = Member(name: 'Imran', sex: 'M', colorValue: 0xffeb6834);
    await db.saveMember(wife);
    await db.saveMember(me);

    final ai = AiSettings.instance
      ..provider = AiProvider.local
      ..perProvider[AiProvider.local]!.baseUrl = server.url
      ..perProvider[AiProvider.local]!.model = 'test-vision';
    await ai.save();
    expect(ai.enabled, isTrue);

    await tester.pumpWidget(const FamilyHealthApp());
    await settle(tester);

    // ---- 1. The server is down hard: friendly error, file kept, retry works.
    server.reply = (_) => (
      404,
      {
        'error': {'message': 'model "test-vision" not found'},
      },
    );
    final pdf = await fixture('cbc_text.pdf');
    FileIO.debugPick = (_) async => [pdf];
    await tester.tap(find.byTooltip('Import a document'));
    await settle(tester);
    await tapText(tester, 'Choose PDFs or images');
    await waitFor(tester, find.textContaining("isn't available on your account"));
    expect(find.text('Try again'), findsOneWidget);
    expect(find.textContaining('Your file is safe'), findsOneWidget);
    expect(server.requests, hasLength(1), reason: 'a missing model is not retried');

    // The page image really went out, and nothing about the family did.
    final sent = jsonEncode(server.requests.single);
    expect(sent, contains('data:image/jpeg;base64,'));
    expect(sent, isNot(contains('Nadia')));
    expect(sent, isNot(contains('Imran')));

    // ---- 2. Retry: names the other member, and one value is invented.
    server.reply = (_) => modelSays(
      document(
        patient: 'Mr. Imran',
        doctor: 'Dr. Rafiq Islam, MBBS',
        followDays: 30,
        rows: [labRow('Hemoglobin', '99.9', 'g/dL', '13 - 17'), labRow('Ferritin', '42', 'ng/mL', '30 - 400')],
      ),
    );
    await tapText(tester, 'Try again');
    await waitFor(tester, find.textContaining('filed under Imran'));
    expect(find.text('Ferritin', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('not found by the on-device reader', skipOffstage: false), findsWidgets);
    expect(find.text('New: Dr. Rafiq Islam, MBBS', skipOffstage: false), findsOneWidget);

    // Unverified values stop a one-tap save.
    await tapText(tester, 'Save');
    await waitFor(tester, find.textContaining('not verified'));
    await tapText(tester, 'Save anyway');
    await waitFor(tester, find.text('Family'));

    final reports = await db.reports(me.id);
    expect(reports, hasLength(1), reason: 'filed under the member named on the document');
    expect(await db.reports(wife.id), isEmpty);
    final report = reports.single;
    expect(report.extractedBy, 'Local model · test-vision');
    expect(report.followUp, isNotNull);
    expect((await db.attachments(report.id)).single.isPdf, isTrue, reason: 'the original PDF is stored with the data');
    final doctors = await db.doctors();
    expect(doctors.single.name, 'Dr. Rafiq Islam, MBBS');
    expect(report.doctorId, doctors.single.id);
    expect(doctors.single.hospital, 'City General Hospital');

    // ---- 3. Same file again is spotted before anything is sent.
    server.requests.clear();
    final again = await fixture('cbc_text.pdf');
    FileIO.debugPick = (_) async => [again];
    await tester.tap(find.byTooltip('Import a document'));
    await settle(tester);
    await tapText(tester, 'Choose PDFs or images');
    await waitFor(tester, find.text('Already saved'));
    await tapText(tester, 'Cancel');
    expect(server.requests, isEmpty);

    // ---- 4. A prescription for the wife, same doctor: medicines and reminders in one save.
    server.reply = (_) => modelSays(
      document(
        type: 'prescription',
        patient: 'Nadia Rahman',
        doctor: 'Prof. Dr. Rafiq Islam',
        medicines: [
          {
            'name_printed': 'Napa',
            'strength_printed': '500 mg',
            'schedule_printed': '১+০+১',
            'duration_printed': '৭ দিন',
            'instructions_printed': 'খাবার পরে',
            'legible': true,
            'source_text': 'Napa',
          },
        ],
      ),
    );
    final photo = await fixture('cbc_photo.jpg');
    FileIO.debugPick = (_) async => [photo];
    await tester.tap(find.byTooltip('Import a document'));
    await settle(tester);
    await tapText(tester, 'Choose PDFs or images');
    await waitFor(tester, find.text('Medicines found'));
    await tapText(tester, 'Save');
    if (find.text('Save anyway').evaluate().isNotEmpty) await tapText(tester, 'Save anyway');
    await waitFor(tester, find.text('Family'));

    final rx = (await db.reports(wife.id)).single;
    expect(rx.type, DocType.prescription);
    expect(rx.doctorId, doctors.single.id, reason: 'matched the same doctor despite the different title');
    expect(await db.doctors(), hasLength(1));
    final meds = await db.medications(memberId: wife.id);
    expect(meds.single.times, [480, 1200]);
    expect(meds.single.days, 7);
    expect(meds.single.reportId, rx.id);

    // ---- 5. The doctor's page holds both people's records.
    await tester.tap(find.byTooltip('Doctors'));
    await settle(tester);
    await tapText(tester, 'Dr. Rafiq Islam, MBBS');
    await waitFor(tester, find.byType(DoctorDetailScreen));
    expect(find.text('Everyone'), findsOneWidget);
    expect(find.text('Fever consultation'), findsOneWidget);
    expect(find.text('Complete Blood Count'), findsOneWidget);
    await tapText(tester, 'Nadia Rahman');
    expect(find.text('Complete Blood Count'), findsNothing, reason: 'filtered to one patient');
    expect(find.text('Fever consultation'), findsOneWidget);

    // ---- 6. Doctors and photos survive a one-member backup and restore.
    final photoFile = '${newId()}.jpg';
    await FileStore.instance.writePlain(photoFile, fixtureBytes('cbc_photo.jpg'));
    await db.saveMember(wife..photoFile = photoFile);
    final backup = await BackupService.export(memberId: wife.id, password: 'correct horse');
    await closeDb();

    final other = TestStorage('ai_restore');
    await other.wipe();
    await other.boot();
    final summary = await BackupService.import(backup, password: 'correct horse');
    expect(summary.members, 1);
    expect((await AppDb.instance.doctors()).single.name, 'Dr. Rafiq Islam, MBBS');
    final restored = (await AppDb.instance.members()).single;
    expect(await FileStore.instance.readPlain(restored.photoFile!), fixtureBytes('cbc_photo.jpg'));
    expect((await AppDb.instance.reports(restored.id)).single.doctorId, isNotNull);
    await closeDb();
    await other.wipe();
    await storage.wipe();
  });
}
