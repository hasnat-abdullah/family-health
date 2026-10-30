import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../services/reminders.dart';
import '../widgets/common.dart';

class MedicationFormScreen extends StatefulWidget {
  const MedicationFormScreen({super.key, required this.member, this.medication, this.reportId, this.fromPrescription = false});
  final Member member;
  final Medication? medication;
  final String? reportId;

  /// Opened right after saving a prescription: offer "add another".
  final bool fromPrescription;

  @override
  State<MedicationFormScreen> createState() => _MedicationFormScreenState();
}

class _MedicationFormScreenState extends State<MedicationFormScreen> {
  static const _presets = {
    'Once a day': [8 * 60],
    'Twice a day': [8 * 60, 20 * 60],
    '3 times a day': [8 * 60, 14 * 60, 20 * 60],
    '4 times a day': [8 * 60, 12 * 60, 16 * 60, 20 * 60],
  };

  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.medication?.name);
  late final _dose = TextEditingController(text: widget.medication?.dose);
  late final _instructions = TextEditingController(text: widget.medication?.instructions);
  late final _days = TextEditingController(text: '${widget.medication?.days ?? 7}');
  late List<int> _times = [...?widget.medication?.times ?? _presets['Twice a day']];
  late DateTime _start = widget.medication?.startDate ?? DateTime.now();
  late bool _ongoing = widget.medication != null && widget.medication!.days == null;
  late bool _reminders = widget.medication?.reminders ?? true;
  int _added = 0;

  Future<bool> _save() async {
    if (!_form.currentState!.validate()) return false;
    if (_times.isEmpty) {
      showMessage(context, 'Add at least one dose time.');
      return false;
    }
    final m = widget.medication ??
        Medication(memberId: widget.member.id, reportId: widget.reportId, name: '', times: const [], startDate: _start);
    m
      ..name = _name.text.trim()
      ..dose = _dose.text.trim().isEmpty ? null : _dose.text.trim()
      ..instructions = _instructions.text.trim().isEmpty ? null : _instructions.text.trim()
      ..times = ([..._times]..sort())
      ..startDate = _start
      ..days = _ongoing ? null : int.parse(_days.text.trim())
      ..reminders = _reminders;
    if (_reminders) {
      final granted = await Reminders.requestPermission();
      if (!granted && mounted) {
        showMessage(context, 'Notifications are off for this app — turn them on in Settings to get reminders.');
      }
    }
    await AppDb.instance.saveMedication(m);
    return true;
  }

  Future<void> _saveAndClose() async {
    if (await _save() && mounted) Navigator.pop(context);
  }

  Future<void> _saveAndAddAnother() async {
    if (!await _save() || !mounted) return;
    setState(() {
      _added++;
      _name.clear();
      _dose.clear();
      _instructions.clear();
    });
    showMessage(context, 'Saved. Add the next medicine.');
  }

  Future<void> _addTime() async {
    final t = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 8, minute: 0));
    if (t == null) return;
    final minutes = t.hour * 60 + t.minute;
    if (!_times.contains(minutes)) setState(() => _times = [..._times, minutes]..sort());
  }

  Future<void> _editTime(int index) async {
    final cur = _times[index];
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: cur ~/ 60, minute: cur % 60));
    if (t == null) return;
    setState(() => _times = ([..._times]..[index] = t.hour * 60 + t.minute)..sort());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const gap = SizedBox(height: 16);
    final days = int.tryParse(_days.text.trim());
    final end = (!_ongoing && days != null && days > 0) ? DateTime(_start.year, _start.month, _start.day + days - 1) : null;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.medication == null ? 'Add medicine · ${widget.member.name}' : 'Edit medicine'),
        actions: [
          Padding(padding: const EdgeInsets.only(right: 12), child: FilledButton(onPressed: _saveAndClose, child: const Text('Save'))),
        ],
      ),
      body: ContentWidth(
        maxWidth: 560,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (widget.fromPrescription)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    _added == 0 ? 'Prescription saved. Add each medicine on it to get reminders until the course is finished.' : '$_added medicine(s) added from this prescription.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              TextFormField(
                controller: _name,
                autofocus: widget.medication == null,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Medicine name', hintText: 'e.g. Amoxicillin 500'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter the medicine' : null,
              ),
              gap,
              TextFormField(
                controller: _dose,
                decoration: const InputDecoration(labelText: 'Dose (optional)', hintText: 'e.g. 1 tablet, 5 ml'),
              ),
              gap,
              Text('How often', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in _presets.entries)
                  ChoiceChip(
                    label: Text(e.key),
                    selected: _sameTimes(_times, e.value),
                    onSelected: (_) => setState(() => _times = [...e.value]),
                  ),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (i, t) in _times.indexed)
                  InputChip(
                    avatar: const Icon(Icons.alarm_rounded, size: 18),
                    label: Text(formatTime(context, t)),
                    onPressed: () => _editTime(i),
                    onDeleted: () => setState(() => _times = [..._times]..removeAt(i)),
                  ),
                ActionChip(avatar: const Icon(Icons.add_rounded, size: 18), label: const Text('Add time'), onPressed: _addTime),
              ]),
              gap,
              Row(children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: _start,
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (d != null) setState(() => _start = d);
                    },
                    child: InputDecorator(
                      decoration: const InputDecoration(labelText: 'Start date', suffixIcon: Icon(Icons.calendar_today_rounded)),
                      child: Text(dateFmt.format(_start)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _days,
                    enabled: !_ongoing,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'For how many days'),
                    onChanged: (_) => setState(() {}),
                    validator: (v) {
                      if (_ongoing) return null;
                      final n = int.tryParse(v?.trim() ?? '');
                      return (n == null || n < 1 || n > 3650) ? 'Enter days' : null;
                    },
                  ),
                ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Ongoing (no end date)'),
                subtitle: const Text('For long-term medicines such as thyroid or BP tablets'),
                value: _ongoing,
                onChanged: (v) => setState(() => _ongoing = v),
              ),
              if (end != null)
                Text(
                  'Course ends ${dateFmt.format(end)} · ${days! * _times.length} doses in total',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              gap,
              TextFormField(
                controller: _instructions,
                decoration: const InputDecoration(labelText: 'Instructions (optional)', hintText: 'e.g. after meal, with water'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text('Remind me'),
                subtitle: const Text('A notification at each dose time until the course ends'),
                value: _reminders,
                onChanged: (v) => setState(() => _reminders = v),
              ),
              if (widget.fromPrescription) ...[
                gap,
                OutlinedButton.icon(onPressed: _saveAndAddAnother, icon: const Icon(Icons.add_rounded), label: const Text('Save & add another medicine')),
              ],
              if (widget.medication != null) ...[
                gap,
                TextButton.icon(
                  onPressed: () async {
                    final ok = await confirm(context, title: 'Delete ${widget.medication!.name}?', message: 'Its reminders and dose history will be removed.');
                    if (!ok) return;
                    await AppDb.instance.deleteMedication(widget.medication!.id);
                    if (context.mounted) Navigator.pop(context);
                  },
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Delete medicine'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static bool _sameTimes(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);
}
