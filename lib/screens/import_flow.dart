import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/lab_catalog.dart';
import '../data/models.dart';
import '../data/storage.dart';
import '../services/ai/ai_config.dart';
import '../services/file_io.dart';
import '../services/report_parser.dart';
import '../services/report_reader.dart';
import '../widgets/common.dart';
import 'report_editor_screen.dart';

/// One-stop import from the home screen: pick files, and each one is filed under
/// the right person. With AI on, that person comes from the document itself.
Future<void> smartImport(BuildContext context) async {
  final family = await AppDb.instance.members();
  if (!context.mounted) return;
  if (family.isEmpty) {
    showMessage(context, 'Add a family member first.');
    return;
  }
  final source = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMobile)
            ListTile(
              leading: const Icon(Icons.photo_camera_rounded),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
          if (isMobile)
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: const Text('Choose from photos'),
              onTap: () => Navigator.pop(context, 'photos'),
            ),
          ListTile(
            leading: const Icon(Icons.upload_file_rounded),
            title: const Text('Choose PDFs or images'),
            subtitle: const Text('Select several to work through a pile'),
            onTap: () => Navigator.pop(context, 'files'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  final picked = switch (source) {
    'camera' => [?await FileIO.takePhoto()],
    'photos' => await FileIO.pickImages(),
    _ => await FileIO.pickReports(),
  };
  if (picked.isEmpty || !context.mounted) return;

  var member = family.length == 1 ? family.single : null;
  if (member == null && !AiSettings.instance.enabled) {
    member = await _askMember(context, family);
    if (member == null || !context.mounted) {
      await FileIO.discardPlainCopies(picked);
      return;
    }
  }

  var batches = [picked];
  if (picked.length > 1) {
    final separate = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${picked.length} files'),
        content: const Text('Are these pages of one report, or separate reports?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('One report')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Separate reports')),
        ],
      ),
    );
    if (separate == null) {
      await FileIO.discardPlainCopies(picked);
      return;
    }
    if (separate) {
      batches = [
        for (final f in picked) [f],
      ];
    }
  }
  for (final (i, batch) in batches.indexed) {
    if (!context.mounted) return;
    await ingestFiles(
      context,
      member: member,
      picked: batch,
      queueLabel: batches.length > 1 ? '${i + 1} of ${batches.length}' : null,
    );
  }
}

Future<Member?> _askMember(BuildContext context, List<Member> family) => showDialog<Member>(
  context: context,
  builder: (context) => SimpleDialog(
    title: const Text('Whose record is this?'),
    children: [
      for (final m in family)
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, m),
          child: Row(
            children: [
              MemberAvatar(m, radius: 16),
              const SizedBox(width: 12),
              Expanded(child: Text(m.name)),
            ],
          ),
        ),
    ],
  ),
);

/// Warns when a file is already in the archive, which saves re-reading (and
/// paying for) a report from a pile that has been imported before.
Future<bool> _skipDuplicate(BuildContext context, List<Picked> picked) async {
  for (final f in picked) {
    final hash = FileStore.hashOf(await f.file.readAsBytes());
    final existing = await AppDb.instance.reportWithFile(hash);
    if (existing == null || !context.mounted) continue;
    final who = await AppDb.instance.member(existing.memberId);
    if (!context.mounted) return true;
    final add = await confirm(
      context,
      title: 'Already saved',
      message:
          '${f.name} is already in "${existing.title}" (${dateFmt.format(existing.date)}) for ${who?.name ?? 'a family member'}.',
      action: 'Add again',
    );
    return !add;
  }
  return false;
}

/// Copies the originals into the archive, reads them, and opens the review screen.
Future<void> ingestFiles(
  BuildContext context, {
  Member? member,
  required List<Picked> picked,
  DocType? type,
  String? queueLabel,
}) async {
  if (await _skipDuplicate(context, picked)) {
    await FileIO.discardPlainCopies(picked);
    return;
  }
  if (!context.mounted) return;
  final reportId = newId();
  final progress = ValueNotifier('Saving original…');
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      content: Row(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 20),
          Expanded(
            child: ValueListenableBuilder(valueListenable: progress, builder: (_, text, _) => Text(text)),
          ),
        ],
      ),
    ),
  );

  final attachments = <Attachment>[];
  final lines = <String>[];
  String? readError;
  try {
    for (final (i, f) in picked.indexed) {
      progress.value = picked.length == 1 ? 'Reading report…' : 'Reading page ${i + 1} of ${picked.length}…';
      // Read from the picked file before it is encrypted into the store.
      try {
        lines.addAll(await ReportReader.readLines(f.file));
      } catch (e) {
        readError = '$e';
      }
      attachments.add(await FileStore.instance.importFile(f.file, reportId: reportId, originalName: f.name));
    }
  } finally {
    await FileIO.discardPlainCopies(picked);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
  if (!context.mounted) return;

  final ai = AiSettings.instance.enabled;
  final parsed = ReportParser(sex: member?.sex).parse(lines);
  final title = parsed.results.any((r) => panelFor(r.testKey) == 'Complete Blood Count')
      ? 'CBC'
      : p.basenameWithoutExtension(picked.first.name);
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ReportEditorScreen.create(
        member: member,
        reportId: reportId,
        title: type == null ? title : null,
        date: parsed.date,
        attachments: attachments,
        parsed: type == null ? parsed.results : const [],
        type: type ?? DocType.lab,
        localLines: lines,
        autoAi: ai,
        queueLabel: queueLabel,
        notice: ai
            ? null
            : readError != null
            ? "Couldn't read the file automatically ($readError). The original is attached — add values below."
            : parsed.results.isEmpty
            ? 'No lab values were recognised. The original is attached — you can add values below.'
            : 'Found ${parsed.results.length} values. Please check them against the original before saving.',
      ),
    ),
  );
}
