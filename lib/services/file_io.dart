import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/models.dart';
import '../data/storage.dart';

bool get isMobile => Platform.isIOS || Platform.isAndroid;

/// A picked file plus its display name.
typedef Picked = ({File file, String name});

class FileIO {
  /// Test hooks standing in for the system file dialogs, which can't be automated.
  @visibleForTesting
  static Future<List<Picked>> Function(List<String>? extensions)? debugPick;
  @visibleForTesting
  static Future<bool> Function(String fileName, Uint8List bytes)? debugSave;

  static Future<List<Picked>> pickReports() => _pick(FileType.custom, ['pdf', 'jpg', 'jpeg', 'png', 'heic', 'webp']);

  static Future<List<Picked>> pickImages() => _pick(FileType.image, null);

  static Future<Picked?> pickImage() async => (await _pick(FileType.image, null, multiple: false)).firstOrNull;

  static Future<Picked?> pickOne(List<String> extensions) async =>
      (await _pick(FileType.custom, extensions, multiple: false)).firstOrNull;

  /// Backups are picked unfiltered and validated by content: Android filters by
  /// MIME type and has none for `.medarchive`, so a filter would grey the file out.
  static Future<Picked?> pickBackup() async => (await _pick(FileType.any, null, multiple: false)).firstOrNull;

  static Future<List<Picked>> _pick(FileType type, List<String>? extensions, {bool multiple = true}) async {
    if (debugPick != null) return debugPick!(extensions);
    final files = multiple
        ? await FilePicker.pickFiles(type: type, allowedExtensions: extensions)
        : [?await FilePicker.pickFile(type: type, allowedExtensions: extensions)];
    final out = <Picked>[];
    for (final f in files) {
      var path = f.path;
      if (path == null) {
        // Content URIs (Android) arrive without a path: copy to temp.
        final tmp = File(p.join((await getTemporaryDirectory()).path, f.name));
        await tmp.writeAsBytes(await f.readAsBytes());
        path = tmp.path;
      }
      out.add((file: File(path), name: f.name));
    }
    return out;
  }

  /// Deletes plain copies that pickers left in this app's temp/cache folders
  /// (camera shots, copies of content URIs). Never touches the user's own files.
  static Future<void> discardPlainCopies(List<Picked> picked) async {
    final roots = [
      (await getTemporaryDirectory()).path,
      (await getApplicationCacheDirectory()).path,
    ].map(p.canonicalize).toList();
    for (final f in picked) {
      final path = p.canonicalize(f.file.path);
      if (!roots.any((r) => p.isWithin(r, path))) continue;
      try {
        if (await f.file.exists()) await f.file.delete();
      } catch (_) {}
    }
  }

  static Future<Picked?> takePhoto() async {
    final shot = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 90, maxWidth: 3000);
    return shot == null ? null : (file: File(shot.path), name: 'Photo ${DateTime.now().toIso8601String().substring(0, 10)}.jpg');
  }

  /// Saves (desktop) or shares (phone/tablet: AirDrop, Files, WhatsApp, email…).
  /// Returns false if the user cancelled.
  static Future<bool> saveOrShare(BuildContext context, String fileName, Uint8List bytes, {String mime = 'application/octet-stream'}) async {
    if (debugSave != null) return debugSave!(fileName, bytes);
    if (isMobile) {
      final box = context.findRenderObject() as RenderBox?;
      final tmp = File(p.join((await getTemporaryDirectory()).path, fileName));
      await tmp.writeAsBytes(bytes);
      try {
        final result = await SharePlus.instance.share(ShareParams(
          files: [XFile(tmp.path, mimeType: mime)],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ));
        return result.status != ShareResultStatus.dismissed;
      } finally {
        if (await tmp.exists()) await tmp.delete();
      }
    }
    final uri = await FilePicker.saveFile(fileName: fileName, bytes: bytes, mimeType: mime, dialogTitle: 'Save $fileName');
    return uri != null;
  }

  /// Shares or saves a decrypted copy of a stored original.
  static Future<void> shareAttachment(BuildContext context, Attachment a) async {
    if (isMobile) {
      final box = context.findRenderObject() as RenderBox?;
      await FileStore.instance.withPlainFile(a, (plain) async {
        await SharePlus.instance.share(ShareParams(
          files: [XFile(plain.path, mimeType: a.mime)],
          fileNameOverrides: [a.originalName],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ));
      });
    } else {
      final bytes = await FileStore.instance.read(a);
      if (context.mounted) await saveOrShare(context, a.originalName, bytes, mime: a.mime);
    }
  }
}
