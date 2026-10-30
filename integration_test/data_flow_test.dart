// Real SQLCipher + encrypted file store on the device.
//   flutter test integration_test/data_flow_test.dart -d macos
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medi_archive/data/database.dart';
import 'package:medi_archive/data/models.dart';
import 'package:medi_archive/data/storage.dart';
import 'package:medi_archive/security/vault.dart';
import 'package:medi_archive/services/backup_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'harness.dart';

bool containsAscii(List<int> haystack, String needle) {
  final n = ascii.encode(needle);
  outer:
  for (var i = 0; i + n.length <= haystack.length; i++) {
    for (var j = 0; j < n.length; j++) {
      if (haystack[i + j] != n[j]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a version 2 database upgrades with its records intact', (_) async {
    final storage = TestStorage('migrate');
    await storage.wipe();
    final path = await storage.dbPath;
    await storage.boot();
    await closeDb();
    await deleteDatabase(path);
    final old = await openDatabase(path, password: Vault.instance.databasePassword, version: 2, onCreate: (db, _) async {
      await db.execute('CREATE TABLE members(id TEXT PRIMARY KEY, name TEXT NOT NULL, relation TEXT, birth_date TEXT, sex TEXT, blood_group TEXT, color INTEGER NOT NULL, notes TEXT, updated_at INTEGER NOT NULL)');
      await db.execute("CREATE TABLE reports(id TEXT PRIMARY KEY, member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE, title TEXT NOT NULL, date TEXT NOT NULL, type TEXT NOT NULL DEFAULT 'lab', lab TEXT, notes TEXT, updated_at INTEGER NOT NULL)");
      await db.execute('CREATE TABLE attachments(id TEXT PRIMARY KEY, report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE, file_name TEXT NOT NULL, original_name TEXT NOT NULL, mime TEXT NOT NULL, updated_at INTEGER NOT NULL)');
      await db.execute('CREATE TABLE results(id TEXT PRIMARY KEY, report_id TEXT NOT NULL, member_id TEXT NOT NULL, test_key TEXT NOT NULL, test_name TEXT NOT NULL, value REAL, value_text TEXT, unit TEXT, ref_low REAL, ref_high REAL, date TEXT NOT NULL, updated_at INTEGER NOT NULL)');
      await db.execute('CREATE TABLE medications(id TEXT PRIMARY KEY, member_id TEXT NOT NULL, report_id TEXT, name TEXT NOT NULL, dose TEXT, times TEXT NOT NULL, start_date TEXT NOT NULL, days INTEGER, instructions TEXT, reminders INTEGER NOT NULL DEFAULT 1, updated_at INTEGER NOT NULL)');
      await db.execute('CREATE TABLE dose_logs(id TEXT PRIMARY KEY, medication_id TEXT NOT NULL, member_id TEXT NOT NULL, slot TEXT NOT NULL, taken_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, UNIQUE(medication_id, slot))');
      await db.insert('members', {'id': 'm1', 'name': 'Old Member', 'color': 1, 'updated_at': 1});
      await db.insert('reports', {'id': 'r1', 'member_id': 'm1', 'title': 'Old CBC', 'date': '2025-01-01', 'lab': 'Dr. Karim', 'updated_at': 1});
    });
    await old.close();

    await AppDb.init(fileName: storage.config.dbName, password: Vault.instance.databasePassword);
    final db = AppDb.instance;
    final member = (await db.members()).single;
    expect((member.name, member.photoFile), ('Old Member', null));
    final report = (await db.reports('m1')).single;
    expect((report.title, report.lab, report.doctorId, report.followUp), ('Old CBC', 'Dr. Karim', null, null));
    final doctor = Doctor(name: 'Dr. New');
    await db.saveDoctor(doctor);
    await db.saveReport(report..doctorId = doctor.id, const [], const []);
    await db.deleteDoctor(doctor.id);
    expect((await db.report('r1'))!.doctorId, isNull, reason: 'deleting a doctor keeps the record');
    await closeDb();
    await storage.wipe();
  });

  testWidgets('records are encrypted at rest; abnormal results, doses, encrypted backup round trip', (_) async {
    final storage = TestStorage('data');
    await storage.wipe();
    await storage.boot();
    final db = AppDb.instance;

    final wife = Member(name: 'Nadia', sex: 'F', colorValue: 0xff2a78d6);
    final me = Member(name: 'Imran', sex: 'M', colorValue: 0xffeb6834);
    await db.saveMember(wife);
    await db.saveMember(me);

    TestResult hb(Report r, double v) => TestResult(
      reportId: r.id, memberId: wife.id, testKey: 'hemoglobin', testName: 'Hemoglobin',
      value: v, unit: 'g/dL', refLow: 12, refHigh: 15.5, date: r.date,
    );
    final jan = Report(memberId: wife.id, title: 'CBC', date: DateTime(2026, 1, 10));
    final feb = Report(memberId: wife.id, title: 'CBC', date: DateTime(2026, 2, 10));
    final esr = TestResult(
      reportId: feb.id, memberId: wife.id, testKey: 'esr', testName: 'ESR',
      value: 32, unit: 'mm/hr', refLow: 0, refHigh: 20, date: feb.date,
    );
    final secretScan = utf8.encode('PATIENT AYESHA HEMOGLOBIN 10.8 SECRET-SCAN-CONTENT');
    final attachment = await FileStore.instance.importBytes(secretScan, reportId: feb.id, originalName: 'scan.jpg');
    await db.saveReport(jan, [hb(jan, 10.9)], const []);
    await db.saveReport(feb, [hb(feb, 12.4), esr], [attachment]);

    expect((await db.attention(wife.id)).map((r) => r.testKey), ['esr']);

    // Re-saving a member must not cascade-delete their reports.
    wife.notes = 'Monthly CBC';
    await db.saveMember(wife);
    expect((await db.reports(wife.id)).length, 2);

    final rx = Report(memberId: wife.id, title: 'Prescription', date: DateTime(2026, 2, 10), type: DocType.prescription);
    await db.saveReport(rx, const [], const []);
    final iron = Medication(memberId: wife.id, reportId: rx.id, name: 'Iron', times: [9 * 60], startDate: DateTime(2026, 2, 10), days: 30);
    await db.saveMedication(iron);
    await db.setTaken(iron, DateTime(2026, 2, 10, 9), true);
    await db.setTaken(iron, DateTime(2026, 2, 10, 9), true); // idempotent
    expect((await db.takenDoses())[iron.id], {'2026-02-10T09:00'});

    // ---- At rest: nothing readable on disk.
    await closeDb();
    final dbBytes = await File(await storage.dbPath).readAsBytes();
    expect(String.fromCharCodes(dbBytes.take(15)), isNot('SQLite format 3'), reason: 'SQLCipher file has no plain header');
    expect(containsAscii(dbBytes, 'Nadia'), isFalse);
    expect(containsAscii(dbBytes, 'Monthly CBC'), isFalse);
    final rawFile = await FileStore.instance.file(attachment.fileName).readAsBytes();
    expect(Vault.isEncryptedFile(rawFile), isTrue);
    expect(containsAscii(rawFile, 'SECRET-SCAN-CONTENT'), isFalse);

    // Wrong key can't open the database.
    await expectLater(
      () async {
        final other = await openDatabase(await storage.dbPath, password: 'not-the-key', singleInstance: false);
        try {
          await other.rawQuery('SELECT count(*) FROM members');
        } finally {
          await other.close();
        }
      }(),
      throwsA(anything),
    );

    // Missing key with existing data: refuses to start instead of starting over.
    final savedKeys = Map.of(storage.keyStore.values);
    storage.keyStore.values.clear();
    await expectLater(storage.boot(), throwsA(isA<VaultLockedException>()));
    expect(await File(await storage.dbPath).exists(), isTrue, reason: 'data left untouched');
    storage.keyStore.values.addAll(savedKeys);
    await storage.boot();
    expect(await FileStore.instance.read(attachment), secretScan);

    // ---- Encrypted backup: export one member, wipe, import on a "new device".
    final archive = await BackupService.export(memberId: wife.id, password: 'family-2026');
    expect(Vault.isEncryptedBackup(archive), isTrue);
    expect(containsAscii(archive, 'Nadia'), isFalse);
    expect(containsAscii(archive, 'SECRET-SCAN-CONTENT'), isFalse);
    await closeDb();

    final device2 = TestStorage('data2');
    await device2.wipe();
    await device2.boot();
    expect(Vault.instance.databasePassword, isNot(savedKeys.values.first), reason: 'other device, other key');
    await expectLater(BackupService.import(archive), throwsA(isA<PasswordRequiredException>()));
    await expectLater(BackupService.import(archive, password: 'wrong-password'), throwsA(isA<WrongPasswordException>()));
    expect(await AppDb.instance.members(), isEmpty);

    final summary = await BackupService.import(archive, password: 'family-2026');
    expect(summary.members, 1);
    expect(summary.reports, 3);
    expect(summary.results, 3);
    expect(summary.medicines, 1);
    expect(summary.files, 1);
    final db2 = AppDb.instance;
    expect((await db2.members()).single.notes, 'Monthly CBC');
    expect((await db2.reports(wife.id)).firstWhere((r) => r.id == rx.id).type, DocType.prescription);
    expect(await FileStore.instance.read(attachment), secretScan);
    // Re-encrypted under device 2's key.
    final raw2 = await FileStore.instance.file(attachment.fileName).readAsBytes();
    expect(Vault.isEncryptedFile(raw2), isTrue);
    expect((await db2.takenDoses())[iron.id], {'2026-02-10T09:00'});
    expect((await BackupService.import(archive, password: 'family-2026')).isEmpty, isTrue);

    await closeDb();
    await storage.wipe();
    await device2.wipe();
  });

  testWidgets('migrates an unencrypted database and files from an older version', (_) async {
    final storage = TestStorage('legacy');
    await storage.wipe();

    // Build an old-style plaintext database and plaintext attachment.
    final path = await storage.dbPath;
    final plain = await openDatabase(path, singleInstance: false);
    await plain.execute('CREATE TABLE members(id TEXT PRIMARY KEY, name TEXT NOT NULL, relation TEXT, birth_date TEXT, '
        'sex TEXT, blood_group TEXT, color INTEGER NOT NULL, notes TEXT, updated_at INTEGER NOT NULL)');
    await plain.execute('''CREATE TABLE reports(id TEXT PRIMARY KEY, member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
        title TEXT NOT NULL, date TEXT NOT NULL, lab TEXT, notes TEXT, updated_at INTEGER NOT NULL)''');
    await plain.execute('''CREATE TABLE attachments(id TEXT PRIMARY KEY, report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
        file_name TEXT NOT NULL, original_name TEXT NOT NULL, mime TEXT NOT NULL, updated_at INTEGER NOT NULL)''');
    await plain.execute('''CREATE TABLE results(id TEXT PRIMARY KEY, report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
        member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE, test_key TEXT NOT NULL, test_name TEXT NOT NULL,
        value REAL, value_text TEXT, unit TEXT, ref_low REAL, ref_high REAL, date TEXT NOT NULL, updated_at INTEGER NOT NULL)''');
    await plain.insert('members', {'id': 'm1', 'name': 'Legacy Nadia', 'color': 1, 'updated_at': 1});
    await plain.insert('reports', {'id': 'r1', 'member_id': 'm1', 'title': 'CBC', 'date': '2025-01-01', 'updated_at': 1});
    await plain.insert('attachments', {'id': 'a1', 'report_id': 'r1', 'file_name': 'old.jpg', 'original_name': 'old.jpg', 'mime': 'image/jpeg', 'updated_at': 1});
    await plain.execute('PRAGMA user_version = 1');
    await plain.close();
    expect(await AppDb.isPlaintext(path), isTrue);
    final dir = await (await storage.filesDir).create(recursive: true);
    await File(p.join(dir.path, 'old.jpg')).writeAsBytes(utf8.encode('OLD-PLAINTEXT-SCAN'));

    await storage.boot();

    expect(await AppDb.isPlaintext(path), isFalse);
    expect((await AppDb.instance.members()).single.name, 'Legacy Nadia');
    final report = (await AppDb.instance.reports('m1')).single;
    expect(report.type, DocType.lab, reason: 'v1 → v2 schema upgrade ran on the migrated file');
    final raw = await File(p.join(dir.path, 'old.jpg')).readAsBytes();
    expect(Vault.isEncryptedFile(raw), isTrue);
    expect(utf8.decode(await FileStore.instance.readPlain('old.jpg')), 'OLD-PLAINTEXT-SCAN');

    await closeDb();
    await storage.wipe();
  });
}
