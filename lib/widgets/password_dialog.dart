import 'package:flutter/material.dart';

import '../services/backup_service.dart';

/// Asks for a new backup password (entered twice). Returns null if cancelled.
Future<String?> askNewBackupPassword(BuildContext context) =>
    showDialog<String>(context: context, builder: (_) => const _PasswordDialog(create: true));

/// Asks for the password of an encrypted backup.
Future<String?> askBackupPassword(BuildContext context, {bool wrongBefore = false}) =>
    showDialog<String>(context: context, builder: (_) => _PasswordDialog(create: false, wrongBefore: wrongBefore));

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.create, this.wrongBefore = false});
  final bool create;
  final bool wrongBefore;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _visible = false;

  void _submit() {
    if (_form.currentState!.validate()) Navigator.pop(context, _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final toggle = IconButton(
      tooltip: _visible ? 'Hide password' : 'Show password',
      icon: Icon(_visible ? Icons.visibility_off_rounded : Icons.visibility_rounded),
      onPressed: () => setState(() => _visible = !_visible),
    );
    return AlertDialog(
      // Scrolls instead of pushing the buttons off-screen when the keyboard is up.
      scrollable: true,
      icon: const Icon(Icons.lock_rounded),
      title: Text(widget.create ? 'Protect this backup' : 'Backup password'),
      content: SizedBox(
        width: 380,
        child: Form(
          key: _form,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              widget.create
                  ? 'The backup file is encrypted with this password. You will need it to import the file on another device.'
                  : 'This backup is encrypted. Enter the password that was set when it was exported.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: const ValueKey('backup-password'),
              controller: _password,
              autofocus: true,
              obscureText: !_visible,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Password',
                suffixIcon: toggle,
                errorText: widget.wrongBefore ? 'Wrong password — try again' : null,
              ),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Enter the password';
                if (widget.create && v.length < BackupService.minPasswordLength) {
                  return 'Use at least ${BackupService.minPasswordLength} characters';
                }
                return null;
              },
              onFieldSubmitted: widget.create ? null : (_) => _submit(),
            ),
            if (widget.create) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('backup-password-confirm'),
                controller: _confirm,
                obscureText: !_visible,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Repeat password'),
                validator: (v) => v != _password.text ? "Passwords don't match" : null,
                onFieldSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 12),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    "If you forget this password, the backup can't be opened by anyone — including you.",
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.create ? 'Encrypt & export' : 'Unlock')),
      ],
    );
  }
}
