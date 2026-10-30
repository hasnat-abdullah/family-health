import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

import 'package:sqflite_sqlcipher/sqflite.dart';

import 'models.dart';
import 'storage.dart';

class DoctorSummary {
  DoctorSummary(this.doctor, this.recordCount, this.lastVisit, this.patients);
  final Doctor doctor;
  final int recordCount;
  final DateTime? lastVisit;
  final List<Member> patients;
}

class MemberSummary {
  MemberSummary(this.member, this.reportCount, this.lastReport, this.attention, this.activeMedicines);
  final Member member;
  final int reportCount;
  final DateTime? lastReport;

  /// Tests whose most recent result is out of range.
  final List<TestResult> attention;
  final int activeMedicines;
}

/// Single local SQLite database. Screens listen to [revision] and reload
/// whenever anything is written.
class AppDb {
  AppDb._(this._db);

  static late AppDb instance;
  final Database _db;
  final revision = ValueNotifier<int>(0);

  /// Tables in parent-before-child order (for export and merge).
  static const tables = ['members', 'doctors', 'reports', 'attachments', 'results', 'medications', 'dose_logs'];

  static Future<String> pathFor(String fileName) async => p.join(await getDatabasesPath(), fileName);

  static Future<bool> exists({String fileName = 'medi_archive.db'}) async => File(await pathFor(fileName)).exists();

  /// Opens the SQLCipher-encrypted database. [fileName] is overridable so tests
  /// never touch real data.
  static Future<void> init({String fileName = 'medi_archive.db', required String password}) async {
    final path = await pathFor(fileName);
    await _encryptIfPlaintext(path, password);
    final db = await openDatabase(
      path,
      password: password,
      version: 3,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE members(
            id TEXT PRIMARY KEY, name TEXT NOT NULL, relation TEXT, birth_date TEXT,
            sex TEXT, blood_group TEXT, color INTEGER NOT NULL, notes TEXT, photo_file TEXT,
            updated_at INTEGER NOT NULL)''');
        await _createDoctorsTable(db);
        await db.execute('''
          CREATE TABLE reports(
            id TEXT PRIMARY KEY,
            member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
            title TEXT NOT NULL, date TEXT NOT NULL, type TEXT NOT NULL DEFAULT 'lab',
            lab TEXT, notes TEXT, doctor_id TEXT REFERENCES doctors(id) ON DELETE SET NULL,
            follow_up TEXT, extracted_by TEXT, updated_at INTEGER NOT NULL)''');
        await db.execute('''
          CREATE TABLE attachments(
            id TEXT PRIMARY KEY,
            report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
            file_name TEXT NOT NULL, original_name TEXT NOT NULL, mime TEXT NOT NULL, sha256 TEXT,
            updated_at INTEGER NOT NULL)''');
        await db.execute('''
          CREATE TABLE results(
            id TEXT PRIMARY KEY,
            report_id TEXT NOT NULL REFERENCES reports(id) ON DELETE CASCADE,
            member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
            test_key TEXT NOT NULL, test_name TEXT NOT NULL, value REAL, value_text TEXT,
            unit TEXT, ref_low REAL, ref_high REAL, date TEXT NOT NULL,
            updated_at INTEGER NOT NULL)''');
        await db.execute('CREATE INDEX idx_reports_member ON reports(member_id, date)');
        await db.execute('CREATE INDEX idx_results_trend ON results(member_id, test_key, date)');
        await db.execute('CREATE INDEX idx_results_report ON results(report_id)');
        await db.execute('CREATE INDEX idx_reports_doctor ON reports(doctor_id)');
        await db.execute('CREATE INDEX idx_attachments_hash ON attachments(sha256)');
        await _createMedicationTables(db);
      },
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute("ALTER TABLE reports ADD COLUMN type TEXT NOT NULL DEFAULT 'lab'");
          await _createMedicationTables(db);
        }
        if (from < 3) {
          await _createDoctorsTable(db);
          await db.execute('ALTER TABLE members ADD COLUMN photo_file TEXT');
          await db.execute('ALTER TABLE reports ADD COLUMN doctor_id TEXT REFERENCES doctors(id) ON DELETE SET NULL');
          await db.execute('ALTER TABLE reports ADD COLUMN follow_up TEXT');
          await db.execute('ALTER TABLE reports ADD COLUMN extracted_by TEXT');
          await db.execute('ALTER TABLE attachments ADD COLUMN sha256 TEXT');
          await db.execute('CREATE INDEX idx_reports_doctor ON reports(doctor_id)');
          await db.execute('CREATE INDEX idx_attachments_hash ON attachments(sha256)');
        }
      },
    );
    instance = AppDb._(db);
  }

  /// True if [path] is an unencrypted SQLite file (written before encryption was added).
  static Future<bool> isPlaintext(String path) async {
    final f = File(path);
    if (!await f.exists()) return false;
    final raf = await f.open();
    try {
      return String.fromCharCodes(await raf.read(15)) == 'SQLite format 3';
    } finally {
      await raf.close();
    }
  }

  /// One-time migration: copies a plaintext database into an encrypted one.
  static Future<void> _encryptIfPlaintext(String path, String password) async {
    if (!await isPlaintext(path)) return;
    final tmp = '$path.encrypting';
    if (await File(tmp).exists()) await File(tmp).delete();
    final plain = await openDatabase(path, singleInstance: false);
    try {
      final version = (await plain.rawQuery('PRAGMA user_version')).first.values.first as int;
      final escaped = tmp.replaceAll("'", "''");
      await plain.execute("ATTACH DATABASE '$escaped' AS encrypted KEY '$password'");
      await plain.rawQuery("SELECT sqlcipher_export('encrypted')");
      await plain.execute('PRAGMA encrypted.user_version = $version');
      await plain.execute('DETACH DATABASE encrypted');
    } finally {
      await plain.close();
    }
    await File(tmp).rename(path);
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final f = File('$path$suffix');
      if (await f.exists()) await f.delete();
    }
  }

  Future<void> close() => _db.close();

  static Future<void> _createDoctorsTable(Database db) => db.execute('''
    CREATE TABLE doctors(
      id TEXT PRIMARY KEY, name TEXT NOT NULL, specialty TEXT, hospital TEXT, phone TEXT,
      notes TEXT, updated_at INTEGER NOT NULL)''');

  static Future<void> _createMedicationTables(Database db) async {
    await db.execute('''
      CREATE TABLE medications(
        id TEXT PRIMARY KEY,
        member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
        report_id TEXT REFERENCES reports(id) ON DELETE SET NULL,
        name TEXT NOT NULL, dose TEXT, times TEXT NOT NULL, start_date TEXT NOT NULL,
        days INTEGER, instructions TEXT, reminders INTEGER NOT NULL DEFAULT 1,
        updated_at INTEGER NOT NULL)''');
    await db.execute('''
      CREATE TABLE dose_logs(
        id TEXT PRIMARY KEY,
        medication_id TEXT NOT NULL REFERENCES medications(id) ON DELETE CASCADE,
        member_id TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
        slot TEXT NOT NULL, taken_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        UNIQUE(medication_id, slot))''');
  }

  void _changed() => revision.value++;

  /// Update-or-insert. (`ConflictAlgorithm.replace` would delete the old row
  /// first, which cascades and wipes the record's children.)
  static Future<void> _upsert(DatabaseExecutor db, String table, Map<String, Object?> row) async {
    final updated = await db.update(table, row, where: 'id = ?', whereArgs: [row['id']]);
    if (updated == 0) await db.insert(table, row);
  }

  // ---- Members

  Future<List<Member>> members() async =>
      (await _db.query('members', orderBy: 'name COLLATE NOCASE')).map(Member.fromMap).toList();

  Future<Member?> member(String id) async {
    final rows = await _db.query('members', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Member.fromMap(rows.first);
  }

  Future<List<MemberSummary>> memberSummaries() async {
    final list = await members();
    final today = DateTime.now();
    return Future.wait(list.map((m) async {
      final stats = await _db.rawQuery(
        'SELECT COUNT(*) AS n, MAX(date) AS last FROM reports WHERE member_id = ?',
        [m.id],
      );
      final last = stats.first['last'] as String?;
      final meds = (await medications(memberId: m.id)).where((x) => x.isActiveOn(today)).length;
      return MemberSummary(m, stats.first['n'] as int, last == null ? null : dateFromDb(last), await attention(m.id), meds);
    }));
  }

  Future<void> saveMember(Member m) async {
    m.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _upsert(_db, 'members', m.toMap());
    _changed();
  }

  Future<void> deleteMember(String id) async {
    final files = await _db.rawQuery(
      'SELECT a.file_name FROM attachments a JOIN reports r ON r.id = a.report_id WHERE r.member_id = ?',
      [id],
    );
    final photo = (await member(id))?.photoFile;
    await _db.delete('members', where: 'id = ?', whereArgs: [id]);
    for (final f in files) {
      await FileStore.instance.delete(f['file_name'] as String);
    }
    if (photo != null) await FileStore.instance.delete(photo);
    _changed();
  }

  // ---- Doctors

  Future<List<Doctor>> doctors() async =>
      (await _db.query('doctors', orderBy: 'name COLLATE NOCASE')).map(Doctor.fromMap).toList();

  Future<Doctor?> doctor(String id) async {
    final rows = await _db.query('doctors', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Doctor.fromMap(rows.first);
  }

  Future<List<DoctorSummary>> doctorSummaries() async {
    final people = {for (final m in await members()) m.id: m};
    return Future.wait((await doctors()).map((d) async {
      final rows = await _db.query('reports', columns: ['member_id', 'date'], where: 'doctor_id = ?', whereArgs: [d.id], orderBy: 'date DESC');
      final patients = rows.map((r) => r['member_id'] as String).toSet();
      return DoctorSummary(
        d,
        rows.length,
        rows.isEmpty ? null : dateFromDb(rows.first['date'] as String),
        [for (final id in patients) ?people[id]],
      );
    }));
  }

  Future<void> saveDoctor(Doctor d) async {
    d.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _upsert(_db, 'doctors', d.toMap());
    _changed();
  }

  /// Removes the doctor only; their records stay with each family member.
  Future<void> deleteDoctor(String id) async {
    await _db.delete('doctors', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Records linked to a doctor, across the family, newest first.
  Future<List<Report>> reportsForDoctor(String doctorId) async => (await _db.query(
    'reports',
    where: 'doctor_id = ?',
    whereArgs: [doctorId],
    orderBy: 'date DESC, updated_at DESC',
  )).map(Report.fromMap).toList();

  // ---- Reports & documents

  Future<List<Report>> reports(String memberId) async => (await _db.query(
    'reports',
    where: 'member_id = ?',
    whereArgs: [memberId],
    orderBy: 'date DESC, updated_at DESC',
  )).map(Report.fromMap).toList();

  Future<Report?> report(String id) async {
    final rows = await _db.query('reports', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : Report.fromMap(rows.first);
  }

  /// Saves a report with its full set of results and attachments, replacing
  /// whatever was stored for it before. Attachment files no longer referenced
  /// are deleted from disk.
  Future<void> saveReport(Report report, List<TestResult> results, List<Attachment> attachments) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    report.updatedAt = now;
    final previous = await this.attachments(report.id);
    await _db.transaction((txn) async {
      await _upsert(txn, 'reports', report.toMap());
      await txn.delete('results', where: 'report_id = ?', whereArgs: [report.id]);
      await txn.delete('attachments', where: 'report_id = ?', whereArgs: [report.id]);
      final batch = txn.batch();
      for (final r in results) {
        r
          ..reportId = report.id
          ..memberId = report.memberId
          ..date = report.date
          ..updatedAt = now;
        batch.insert('results', r.toMap());
      }
      for (final a in attachments) {
        batch.insert('attachments', a.toMap());
      }
      await batch.commit(noResult: true);
    });
    final kept = attachments.map((a) => a.fileName).toSet();
    for (final a in previous.where((a) => !kept.contains(a.fileName))) {
      await FileStore.instance.delete(a.fileName);
    }
    _changed();
  }

  /// Reports with a follow-up date from today on, soonest first.
  Future<List<Report>> upcomingFollowUps() async => (await _db.query(
    'reports',
    where: 'follow_up >= ?',
    whereArgs: [dateToDb(DateTime.now())],
    orderBy: 'follow_up ASC',
  )).map(Report.fromMap).toList();

  /// The record that already holds a file with these bytes, if any.
  Future<Report?> reportWithFile(String sha256) async {
    final rows = await _db.rawQuery(
      'SELECT r.* FROM reports r JOIN attachments a ON a.report_id = r.id WHERE a.sha256 = ? LIMIT 1',
      [sha256],
    );
    return rows.isEmpty ? null : Report.fromMap(rows.first);
  }

  Future<void> deleteReport(String id) async {
    final files = await attachments(id);
    await _db.delete('reports', where: 'id = ?', whereArgs: [id]);
    for (final a in files) {
      await FileStore.instance.delete(a.fileName);
    }
    _changed();
  }

  Future<List<Attachment>> attachments(String reportId) async => (await _db.query(
    'attachments',
    where: 'report_id = ?',
    whereArgs: [reportId],
  )).map(Attachment.fromMap).toList();

  Future<Map<String, int>> attachmentCounts(String memberId) async {
    final rows = await _db.rawQuery(
      'SELECT a.report_id, COUNT(*) AS n FROM attachments a JOIN reports r ON r.id = a.report_id WHERE r.member_id = ? GROUP BY a.report_id',
      [memberId],
    );
    return {for (final r in rows) r['report_id'] as String: r['n'] as int};
  }

  // ---- Results

  Future<List<TestResult>> resultsForReport(String reportId) async => (await _db.query(
    'results',
    where: 'report_id = ?',
    whereArgs: [reportId],
    orderBy: 'rowid',
  )).map(TestResult.fromMap).toList();

  /// All results for a member, oldest first.
  Future<List<TestResult>> resultsForMember(String memberId, {String? testKey}) async => (await _db.query(
    'results',
    where: testKey == null ? 'member_id = ?' : 'member_id = ? AND test_key = ?',
    whereArgs: testKey == null ? [memberId] : [memberId, testKey],
    orderBy: 'date ASC, updated_at ASC',
  )).map(TestResult.fromMap).toList();

  /// Most recent numeric value per test, to spot a misread digit in a new report.
  Future<Map<String, double>> latestValues(String memberId) async => {
    for (final r in await resultsForMember(memberId))
      if (r.value != null) r.testKey: r.value!,
  };

  /// Latest result of every test that is currently out of range, newest first.
  Future<List<TestResult>> attention(String memberId) async {
    final rows = await _db.rawQuery('''
      SELECT r.* FROM results r
      WHERE r.member_id = ? AND r.value IS NOT NULL
        AND r.date = (SELECT MAX(r2.date) FROM results r2 WHERE r2.member_id = r.member_id AND r2.test_key = r.test_key)
        AND ((r.ref_low IS NOT NULL AND r.value < r.ref_low) OR (r.ref_high IS NOT NULL AND r.value > r.ref_high))
      ORDER BY r.date DESC, r.rowid''', [memberId]);
    // Same test twice on the latest date: keep one.
    final seen = <String>{};
    return [
      for (final r in rows.map(TestResult.fromMap))
        if (seen.add(r.testKey)) r,
    ];
  }

  // ---- Medications

  Future<List<Medication>> medications({String? memberId, String? reportId}) async => (await _db.query(
    'medications',
    where: memberId != null ? 'member_id = ?' : (reportId != null ? 'report_id = ?' : null),
    whereArgs: memberId != null ? [memberId] : (reportId != null ? [reportId] : null),
    orderBy: 'start_date DESC, name COLLATE NOCASE',
  )).map(Medication.fromMap).toList();

  Future<void> saveMedication(Medication m) async {
    m.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _upsert(_db, 'medications', m.toMap());
    _changed();
  }

  Future<void> deleteMedication(String id) async {
    await _db.delete('medications', where: 'id = ?', whereArgs: [id]);
    _changed();
  }

  /// Slot keys (see [DoseLog.slotKey]) of doses marked taken, per medication.
  Future<Map<String, Set<String>>> takenDoses({String? memberId}) async {
    final rows = await _db.query(
      'dose_logs',
      columns: ['medication_id', 'slot'],
      where: memberId == null ? null : 'member_id = ?',
      whereArgs: memberId == null ? null : [memberId],
    );
    final out = <String, Set<String>>{};
    for (final r in rows) {
      out.putIfAbsent(r['medication_id'] as String, () => {}).add(r['slot'] as String);
    }
    return out;
  }

  Future<void> setTaken(Medication m, DateTime slot, bool taken) async {
    final key = DoseLog.slotKey(slot);
    if (taken) {
      final exists = await _db.query('dose_logs', where: 'medication_id = ? AND slot = ?', whereArgs: [m.id, key]);
      if (exists.isEmpty) await _db.insert('dose_logs', DoseLog(medicationId: m.id, memberId: m.memberId, slot: slot).toMap());
    } else {
      await _db.delete('dose_logs', where: 'medication_id = ? AND slot = ?', whereArgs: [m.id, key]);
    }
    _changed();
  }

  // ---- Raw access for backup / import

  Future<List<Map<String, Object?>>> rawRows(String table, {String? memberId}) {
    if (memberId == null) return _db.query(table);
    return switch (table) {
      'members' => _db.query(table, where: 'id = ?', whereArgs: [memberId]),
      // Only this member's doctors, which their reports need on the other device.
      'doctors' => _db.rawQuery(
        'SELECT d.* FROM doctors d WHERE d.id IN (SELECT doctor_id FROM reports WHERE member_id = ?)',
        [memberId],
      ),
      'attachments' => _db.rawQuery(
        'SELECT a.* FROM attachments a JOIN reports r ON r.id = a.report_id WHERE r.member_id = ?',
        [memberId],
      ),
      _ => _db.query(table, where: 'member_id = ?', whereArgs: [memberId]),
    };
  }

  /// Inserts rows, keeping whichever copy of a record was updated most recently.
  /// Returns how many rows were added or updated per table.
  Future<Map<String, int>> mergeRows(Map<String, List<Map<String, Object?>>> data) async {
    final counts = <String, int>{};
    await _db.transaction((txn) async {
      for (final table in tables) {
        var n = 0;
        for (final row in data[table] ?? const <Map<String, Object?>>[]) {
          final existing = await txn.query(table, columns: ['updated_at'], where: 'id = ?', whereArgs: [row['id']]);
          if (existing.isNotEmpty && (existing.first['updated_at'] as int) >= (row['updated_at'] as int)) continue;
          if (table == 'dose_logs') {
            // Same dose logged on both devices under different ids.
            final dup = await txn.query(table, where: 'medication_id = ? AND slot = ?', whereArgs: [row['medication_id'], row['slot']]);
            if (dup.isNotEmpty) continue;
          }
          await _upsert(txn, table, row);
          n++;
        }
        counts[table] = n;
      }
    });
    _changed();
    return counts;
  }
}
