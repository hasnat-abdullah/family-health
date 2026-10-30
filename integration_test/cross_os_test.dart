// Real backup exchange between operating systems, driven by tool/cross_os.sh.
// Each device exports an encrypted backup and a CSV into its documents folder,
// waits for the script to deliver the other devices' files, then imports them.
//   flutter test integration_test/cross_os_test.dart -d <device> --dart-define=OS_NAME=<name>
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:family_health/data/database.dart';
import 'package:family_health/data/models.dart';
import 'package:family_health/data/storage.dart';
import 'package:family_health/security/vault.dart';
import 'package:family_health/services/backup_service.dart';
import 'package:family_health/services/csv_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'harness.dart';

const osName = String.fromEnvironment('OS_NAME');
const password = 'পরিবার-family-২০২৬'; // non-ASCII on purpose

String memberId(String os) => 'member-from-$os';

Future<void> seed(String os) async {
  final db = AppDb.instance;
  final m = Member(
    id: memberId(os),
    name: 'আয়েশা Rahman ($os)',
    sex: 'F',
    birthDate: DateTime(1993, 5, 2),
    bloodGroup: 'B+',
    colorValue: 0xffeb6834,
    notes: 'Notes ✓ from $os',
  );
  await db.saveMember(m);
  final cbc = Report(id: 'cbc-$os', memberId: m.id, title: 'CBC', date: DateTime(2026, 3, 14), lab: 'ল্যাব Dhaka');
  final photo = await FileStore.instance.importBytes(
    fixtureBytes('cbc_photo.jpg'),
    reportId: cbc.id,
    originalName: 'রিপোর্ট photo.jpg',
  );
  final pdf = await FileStore.instance.importBytes(
    fixtureBytes('cbc_text.pdf'),
    reportId: cbc.id,
    originalName: 'cbc.pdf',
  );
  await db.saveReport(
    cbc,
    [
      TestResult(
        id: 'hb-$os',
        reportId: cbc.id,
        memberId: m.id,
        testKey: 'hemoglobin',
        testName: 'Hemoglobin',
        value: 10.8,
        unit: 'g/dL',
        refLow: 12,
        refHigh: 15.5,
        date: cbc.date,
      ),
      TestResult(
        id: 'wbc-$os',
        reportId: cbc.id,
        memberId: m.id,
        testKey: 'wbc',
        testName: 'WBC (Total Count)',
        value: 8.2,
        unit: '×10⁹/L',
        refLow: 4,
        refHigh: 11,
        date: cbc.date,
      ),
    ],
    [photo, pdf],
  );
  final rx = Report(
    id: 'rx-$os',
    memberId: m.id,
    title: 'Prescription',
    date: DateTime(2026, 3, 15),
    type: DocType.prescription,
    notes: 'Iron',
  );
  await db.saveReport(rx, const [], const []);
  final iron = Medication(
    id: 'iron-$os',
    memberId: m.id,
    reportId: rx.id,
    name: 'Ferrous sulfate',
    dose: '200 mg',
    times: const [9 * 60, 21 * 60],
    startDate: DateTime(2026, 3, 15),
    days: 30,
  );
  await db.saveMedication(iron);
  await db.setTaken(iron, DateTime(2026, 3, 15, 9), true);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('export here, import from the other operating systems', timeout: const Timeout(Duration(minutes: 40)), (
    _,
  ) async {
    expect(osName, isNotEmpty, reason: 'pass --dart-define=OS_NAME=...');
    final docs = await getApplicationDocumentsDirectory();
    final inbox = await Directory(p.join(docs.path, 'xos_inbox')).create(recursive: true);
    await for (final e in inbox.list()) {
      await e.delete(recursive: true);
    }
    final go = File(p.join(docs.path, 'xos_go'));
    if (await go.exists()) await go.delete();

    final source = TestStorage('xos_src');
    await source.wipe();
    await source.boot();
    await seed(osName);
    await File(p.join(docs.path, 'xos_$osName.medarchive'))
        .writeAsBytes(await BackupService.export(password: password));
    final db = AppDb.instance;
    final m = (await db.members()).single;
    await File(p.join(docs.path, 'xos_$osName.csv'))
        .writeAsString(CsvService.export([m], await db.reports(m.id), await db.resultsForMember(m.id)), encoding: utf8);
    await closeDb();
    await source.wipe();

    // ignore: avoid_print
    print('XOS_READY $osName ${docs.path}');
    final end = DateTime.now().add(const Duration(minutes: 35));
    while (!await go.exists()) {
      if (DateTime.now().isAfter(end)) fail('Timed out waiting for the other devices');
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    final backups = await inbox.list().where((e) => e.path.endsWith('.medarchive')).cast<File>().toList();
    expect(backups, isNotEmpty);
    final target = TestStorage('xos_dst');
    await target.wipe();
    await target.boot();
    final results = <String>[];
    for (final file in backups) {
      final from = RegExp(r'xos_(\w+)\.medarchive').firstMatch(file.path)!.group(1)!;
      expect(from, isNot(osName));
      final bytes = await file.readAsBytes();
      expect(Vault.isEncryptedBackup(bytes), isTrue);
      await expectLater(BackupService.import(bytes, password: 'wrong'), throwsA(isA<WrongPasswordException>()));

      final s = await BackupService.import(bytes, password: password);
      expect([s.members, s.reports, s.results, s.medicines, s.files], [1, 2, 2, 1, 2], reason: 'from $from');
      final d = AppDb.instance;
      final member = (await d.member(memberId(from)))!;
      expect(member.name, 'আয়েশা Rahman ($from)');
      expect(member.notes, 'Notes ✓ from $from');
      expect(member.birthDate, DateTime(1993, 5, 2));
      final reports = await d.reports(member.id);
      final cbc = reports.firstWhere((r) => r.id == 'cbc-$from');
      expect(cbc.lab, 'ল্যাব Dhaka');
      expect(cbc.date, DateTime(2026, 3, 14));
      expect(reports.firstWhere((r) => r.id == 'rx-$from').type, DocType.prescription);
      final values = await d.resultsForReport(cbc.id);
      expect(values.firstWhere((r) => r.testKey == 'wbc').unit, '×10⁹/L');
      expect(values.firstWhere((r) => r.testKey == 'hemoglobin').flag, ResultFlag.low);
      expect((await d.attention(member.id)).map((r) => r.testKey), ['hemoglobin']);

      final files = await d.attachments(cbc.id);
      expect(files.map((a) => a.originalName), containsAll(['রিপোর্ট photo.jpg', 'cbc.pdf']));
      // Original files byte-identical, and re-encrypted with this device's key.
      expect(await FileStore.instance.read(files.firstWhere((a) => !a.isPdf)), fixtureBytes('cbc_photo.jpg'));
      expect(await FileStore.instance.read(files.firstWhere((a) => a.isPdf)), fixtureBytes('cbc_text.pdf'));
      expect(Vault.isEncryptedFile(await FileStore.instance.file(files.first.fileName).readAsBytes()), isTrue);

      final med = (await d.medications(memberId: member.id)).single;
      expect(med.times, [9 * 60, 21 * 60]);
      expect((await d.takenDoses(memberId: member.id))[med.id], {'2026-03-15T09:00'});

      expect(
        (await BackupService.import(bytes, password: password)).isEmpty,
        isTrue,
        reason: 'second import changes nothing',
      );

      // Spreadsheet export from the other OS, into a member here.
      final csv = await File(p.join(inbox.path, 'xos_$from.csv')).readAsString(encoding: utf8);
      final local = Member(id: 'local-$from', name: member.name, sex: 'F', colorValue: 1);
      final parsed = CsvService.parse(csv, local);
      expect(parsed.resultCount, 2, reason: 'csv from $from');
      expect(parsed.reports.single.$1.date, DateTime(2026, 3, 14));
      expect(parsed.reports.single.$2.firstWhere((r) => r.testKey == 'hemoglobin').value, 10.8);
      expect(parsed.reports.single.$2.firstWhere((r) => r.testKey == 'wbc').unit, '×10⁹/L');
      results.add(from);
    }
    expect((await AppDb.instance.members()).length, backups.length);

    await closeDb();
    await target.wipe();
    // ignore: avoid_print
    print('XOS_IMPORTED into=$osName from=${results.join(',')}');
  });
}
