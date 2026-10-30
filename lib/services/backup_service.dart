import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/storage.dart';
import '../security/vault.dart';

class ImportSummary {
  ImportSummary(this.members, this.reports, this.results, this.medicines, this.files);
  final int members;
  final int reports;
  final int results;
  final int medicines;
  final int files;

  bool get isEmpty => members + reports + results + medicines + files == 0;
}

/// Thrown by [BackupService.import] when the backup is encrypted and no password was given.
class PasswordRequiredException implements Exception {
  const PasswordRequiredException();
}

/// `.medarchive` files: a zip holding `data.json` (all rows) plus the original
/// report files under `files/`, encrypted as a whole with a password the user
/// chooses (PBKDF2-SHA256 + AES-256-GCM, see [Vault.encryptWithPassword]).
/// A different device has a different device key, so the backup carries its
/// own password-derived key instead.
///
/// Import merges by record id, keeping the most recently edited copy, so
/// importing the same archive twice is harmless.
class BackupService {
  static const extension = 'medarchive';
  static const _tables = AppDb.tables;
  static const formatVersion = 3;
  static const minPasswordLength = 8;

  /// Exports one member, or everyone when [memberId] is null, encrypted with [password].
  static Future<Uint8List> export({String? memberId, required String password}) async {
    if (password.length < minPasswordLength) throw ArgumentError('Password too short');
    final db = AppDb.instance;
    final data = <String, Object?>{
      'format': 'medi-archive',
      'version': formatVersion,
      'exported_at': DateTime.now().toIso8601String(),
      for (final t in _tables) t: await db.rawRows(t, memberId: memberId),
    };

    final archive = Archive()..add(ArchiveFile.string('data.json', jsonEncode(data)));
    final fileNames = [
      for (final a in data['attachments'] as List<Map<String, Object?>>) a['file_name'] as String,
      for (final m in data['members'] as List<Map<String, Object?>>)
        if (m['photo_file'] != null) m['photo_file'] as String,
    ];
    for (final name in fileNames) {
      if (await FileStore.instance.exists(name)) {
        // Decrypted here; the whole archive is encrypted below. Photos and
        // PDFs are already compressed.
        final bytes = await FileStore.instance.readPlain(name);
        archive.add(ArchiveFile.noCompress('files/$name', bytes.length, bytes));
      }
    }
    return Vault.encryptWithPassword(ZipEncoder().encodeBytes(archive), password);
  }

  static bool isEncrypted(List<int> bytes) => Vault.isEncryptedBackup(bytes);

  /// Imports a backup. Encrypted backups need [password]; throws
  /// [PasswordRequiredException] or [WrongPasswordException] otherwise.
  /// Older unencrypted backups are still accepted.
  static Future<ImportSummary> import(Uint8List bytes, {String? password}) async {
    if (Vault.isEncryptedBackup(bytes)) {
      if (password == null) throw const PasswordRequiredException();
      bytes = await Vault.decryptWithPassword(bytes, password);
    }
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('This is not a Medi Archive backup file.');
    }
    final dataFile = archive.findFile('data.json');
    if (dataFile == null) throw const FormatException('Backup is missing data.json.');
    final data = jsonDecode(utf8.decode(dataFile.content)) as Map<String, Object?>;
    if (data['format'] != 'medi-archive') throw const FormatException('Unknown backup format.');
    if ((data['version'] as int) > formatVersion) {
      throw const FormatException('This backup was made by a newer version of the app. Please update.');
    }

    var files = 0;
    for (final entry in archive.files) {
      if (!entry.isFile || !entry.name.startsWith('files/')) continue;
      final name = entry.name.substring('files/'.length);
      // Only plain file names; never let an archive write outside the store.
      if (name.isEmpty || name != p.basename(name) || name.startsWith('.')) continue;
      if (await FileStore.instance.exists(name)) continue;
      // Re-encrypted with this device's key.
      await FileStore.instance.writePlain(name, entry.content);
      files++;
    }

    final rows = {
      for (final t in _tables)
        t: [for (final r in (data[t] as List? ?? const [])) Map<String, Object?>.from(r as Map)],
    };
    final counts = await AppDb.instance.mergeRows(rows);
    return ImportSummary(counts['members']!, counts['reports']!, counts['results']!, counts['medications']!, files);
  }
}
