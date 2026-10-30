import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../security/vault.dart';
import 'models.dart';

/// Original report files, stored encrypted (AES-256-GCM) in the app's private
/// support directory. Plain bytes exist only in memory, or briefly in a temp
/// file when a native component (OCR, share sheet) needs a path.
class FileStore {
  FileStore._(this.dir, this._vault);

  static late FileStore instance;
  final Directory dir;
  final Vault _vault;

  static Future<void> init({String folder = 'attachments', required Vault vault}) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, folder));
    await dir.create(recursive: true);
    instance = FileStore._(dir, vault);
    await instance._encryptLegacyFiles();
  }

  /// True if the store holds files encrypted with a device key (so a missing
  /// key means data would be lost, not a first run or a pre-encryption install).
  static Future<bool> hasEncryptedFiles({String folder = 'attachments'}) async {
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, folder));
    if (!await dir.exists()) return false;
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final raf = await e.open();
      try {
        if (Vault.isEncryptedFile(await raf.read(4))) return true;
      } finally {
        await raf.close();
      }
    }
    return false;
  }

  File file(String fileName) => File(p.join(dir.path, fileName));

  /// Encrypts [source] into the store and returns an [Attachment] for [reportId].
  Future<Attachment> importFile(File source, {required String reportId, String? originalName}) async {
    final name = originalName ?? p.basename(source.path);
    return importBytes(await source.readAsBytes(), reportId: reportId, originalName: name);
  }

  Future<Attachment> importBytes(List<int> bytes, {required String reportId, required String originalName}) async {
    final ext = p.extension(originalName).toLowerCase();
    final stored = '${newId()}$ext';
    await writePlain(stored, bytes);
    return Attachment(reportId: reportId, fileName: stored, originalName: originalName, mime: mimeFor(ext), sha256: hashOf(bytes));
  }

  static String hashOf(List<int> bytes) => sha256.convert(bytes).toString();

  Future<void> writePlain(String fileName, List<int> bytes) => _writeAtomic(file(fileName), _vault.encryptFile(bytes));

  Future<Uint8List> readPlain(String fileName) async => _vault.decryptFile(await file(fileName).readAsBytes());

  Future<Uint8List> read(Attachment a) => readPlain(a.fileName);

  Future<bool> exists(String fileName) => file(fileName).exists();

  /// Decrypts [a] to a temp file for [use], then deletes it.
  Future<T> withPlainFile<T>(Attachment a, Future<T> Function(File plain) use) async {
    final tmpDir = await Directory(p.join((await getTemporaryDirectory()).path, 'decrypted')).create(recursive: true);
    final tmp = File(p.join(tmpDir.path, '${newId()}${p.extension(a.originalName)}'));
    try {
      await tmp.writeAsBytes(await read(a), flush: true);
      return await use(tmp);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<void> delete(String fileName) async {
    final f = file(fileName);
    if (await f.exists()) await f.delete();
  }

  /// Leftovers from an interrupted [withPlainFile] (e.g. app killed mid-OCR).
  static Future<void> purgeTempPlainFiles() async {
    final d = Directory(p.join((await getTemporaryDirectory()).path, 'decrypted'));
    if (await d.exists()) await d.delete(recursive: true);
  }

  Future<void> _encryptLegacyFiles() async {
    await for (final e in dir.list()) {
      if (e is! File || e.path.endsWith('.part')) continue;
      final bytes = await e.readAsBytes();
      if (!Vault.isEncryptedFile(bytes)) await _writeAtomic(e, _vault.encryptFile(bytes));
    }
  }

  static Future<void> _writeAtomic(File target, Future<Uint8List> data) async {
    final part = File('${target.path}.part');
    await part.writeAsBytes(await data, flush: true);
    await part.rename(target.path);
  }

  static String mimeFor(String ext) => switch (ext.toLowerCase()) {
    '.pdf' => 'application/pdf',
    '.png' => 'image/png',
    '.heic' => 'image/heic',
    '.webp' => 'image/webp',
    _ => 'image/jpeg',
  };
}
