import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../security/app_lock.dart';
import '../security/vault.dart';
import '../services/ai/ai_config.dart';
import '../services/backup_service.dart';
import '../services/csv_service.dart';
import '../services/file_io.dart';
import '../services/reminders.dart';
import '../widgets/common.dart';
import '../widgets/password_dialog.dart';
import 'ai_settings_screen.dart';

String _stamp() => DateFormat('yyyy-MM-dd').format(DateTime.now());

/// Runs [work] behind a modal progress dialog.
Future<T> withProgress<T>(BuildContext context, String message, Future<T> Function() work) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 20),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    ),
  );
  try {
    return await work();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// Asks for a password, then exports one member (or everyone) as an encrypted backup.
Future<void> exportBackupFlow(BuildContext context, {Member? member}) async {
  final password = await askNewBackupPassword(context);
  if (password == null || !context.mounted) return;
  final bytes = await withProgress(
    context,
    'Encrypting backup…',
    () => BackupService.export(memberId: member?.id, password: password),
  );
  if (!context.mounted) return;
  final name = member == null ? 'family' : member.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  final saved = await FileIO.saveOrShare(
    context,
    '$name-${_stamp()}.${BackupService.extension}',
    bytes,
    mime: 'application/octet-stream',
  );
  if (saved && context.mounted) showMessage(context, 'Encrypted backup exported.');
}

Future<void> importBackupFlow(BuildContext context) async {
  final picked = await FileIO.pickBackup();
  if (picked == null || !context.mounted) return;
  final bytes = await picked.file.readAsBytes();
  String? password;
  var wrong = false;
  while (true) {
    if (!context.mounted) return;
    if (BackupService.isEncrypted(bytes)) {
      password = await askBackupPassword(context, wrongBefore: wrong);
      if (password == null || !context.mounted) return;
    }
    try {
      final s = await withProgress(
        context,
        'Decrypting and importing…',
        () => BackupService.import(bytes, password: password),
      );
      // Reminders for imported medicines need permission on this device too.
      if (s.medicines > 0) await Reminders.requestPermission();
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import complete'),
          content: Text(
            s.isEmpty
                ? 'Everything in this backup was already on this device.'
                : 'Added or updated:\n• ${s.members} member profile(s)\n• ${s.reports} report(s) & document(s)\n• ${s.results} result(s)\n• ${s.medicines} medicine(s)\n• ${s.files} original file(s)',
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
        ),
      );
      return;
    } on WrongPasswordException {
      wrong = true;
    } on FormatException catch (e) {
      if (context.mounted) showMessage(context, e.message);
      return;
    }
  }
}

class BackupScreen extends StatelessWidget {
  const BackupScreen({super.key});

  Future<void> _exportCsv(BuildContext context) async {
    final ok = await confirm(
      context,
      title: 'Export unencrypted CSV?',
      message:
          'Spreadsheet files cannot be password-protected. Anyone who gets this file can read the results. '
          'Use an encrypted backup to move records between devices.',
      action: 'Export CSV',
    );
    if (!ok || !context.mounted) return;
    final db = AppDb.instance;
    final members = await db.members();
    final reports = <Report>[];
    final results = <TestResult>[];
    for (final m in members) {
      reports.addAll(await db.reports(m.id));
      results.addAll(await db.resultsForMember(m.id));
    }
    if (!context.mounted) return;
    await FileIO.saveOrShare(
      context,
      'family-results-${_stamp()}.csv',
      utf8.encode(CsvService.export(members, reports, results)),
      mime: 'text/csv',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
      child: Text(t, style: theme.textTheme.titleSmall),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Security & backup')),
      body: DbBuilder<List<Member>>(
        load: AppDb.instance.members,
        builder: (context, members) => ContentWidth(
          maxWidth: 640,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Card(
                child: ListTile(
                  leading: Icon(Icons.verified_user_rounded, color: theme.colorScheme.primary),
                  title: const Text('Your records are encrypted'),
                  subtitle: const Text(
                    'The database and every original photo and PDF are encrypted on this device (AES-256). '
                    'The key is kept in the device\'s secure keychain and never leaves it.',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const _AppLockTile(),
              const SizedBox(height: 12),
              ValueListenableBuilder(
                valueListenable: AiSettings.changed,
                builder: (context, _, _) {
                  final ai = AiSettings.instance;
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.auto_awesome_outlined),
                      title: const Text('AI document reading'),
                      subtitle: Text(ai.enabled ? ai.sourceLabel : 'Off. Documents are only read on this device.'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AiSettingsScreen())),
                    ),
                  );
                },
              ),
              heading('Move to another device'),
              Text(
                'Export an encrypted backup, send the file (AirDrop, Files, email, WhatsApp…), then choose Import on the other device and enter the password. '
                'Importing merges records — nothing already there is deleted.',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('Import a backup'),
                  subtitle: const Text('.medarchive file from this app on any device'),
                  onTap: () => importBackupFlow(context),
                ),
              ),
              heading('Export encrypted backup (includes original photos & PDFs)'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.family_restroom_rounded),
                      title: const Text('Whole family'),
                      subtitle: Text('${members.length} member(s)'),
                      trailing: const Icon(Icons.lock_rounded),
                      enabled: members.isNotEmpty,
                      onTap: () => exportBackupFlow(context),
                    ),
                    for (final m in members)
                      ListTile(
                        leading: MemberAvatar(m, radius: 16),
                        title: Text(m.name),
                        subtitle: m.relation == null ? null : Text(m.relation!),
                        trailing: const Icon(Icons.lock_rounded),
                        onTap: () => exportBackupFlow(context, member: m),
                      ),
                  ],
                ),
              ),
              heading('Spreadsheet'),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.table_chart_rounded),
                  title: const Text('Export all results as CSV'),
                  subtitle: const Text('Not encrypted — values only, for Excel, Numbers or Google Sheets'),
                  enabled: members.isNotEmpty,
                  onTap: () => _exportCsv(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppLockTile extends StatefulWidget {
  const _AppLockTile();

  @override
  State<_AppLockTile> createState() => _AppLockTileState();
}

class _AppLockTileState extends State<_AppLockTile> {
  bool? _available;

  @override
  void initState() {
    super.initState();
    AppLock.authenticator.isAvailable().then((v) {
      if (mounted) setState(() => _available = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final available = _available ?? false;
    return Card(
      child: SwitchListTile(
        secondary: const Icon(Icons.fingerprint_rounded),
        title: const Text('App lock'),
        subtitle: Text(
          _available == false ? 'Set up a passcode, Face ID, Touch ID or fingerprint on this device to use app lock.' : 'Require Face ID, Touch ID, fingerprint or your device passcode to open the app, and after it has been in the background for a minute.',
        ),
        value: AppLock.enabled,
        onChanged: !available
            ? null
            : (v) async {
                final ok = await AppLock.setEnabled(v);
                if (!context.mounted) return;
                setState(() {});
                if (!ok) showMessage(context, "Couldn't verify it's you — app lock unchanged.");
              },
      ),
    );
  }
}
