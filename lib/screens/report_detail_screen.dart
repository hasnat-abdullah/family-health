import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/lab_catalog.dart';
import '../data/models.dart';
import '../widgets/attachment_strip.dart';
import '../widgets/common.dart';
import '../widgets/medicines.dart';
import 'doctors_screen.dart';
import 'medication_form_screen.dart';
import 'report_editor_screen.dart';
import 'trend_screen.dart';

class _Detail {
  _Detail(this.report, this.member, this.results, this.attachments, this.meds, this.doctor);
  final Report report;
  final Member member;
  final List<TestResult> results;
  final List<Attachment> attachments;
  final MedState meds;
  final Doctor? doctor;
}

class ReportDetailScreen extends StatelessWidget {
  const ReportDetailScreen({super.key, required this.reportId});
  final String reportId;

  Future<_Detail?> _load() async {
    final db = AppDb.instance;
    final r = await db.report(reportId);
    if (r == null) return null;
    final m = await db.member(r.memberId);
    if (m == null) return null;
    final meds = await MedState.load(memberId: m.id);
    return _Detail(
      r,
      m,
      await db.resultsForReport(reportId),
      await db.attachments(reportId),
      MedState(meds.medications.where((x) => x.reportId == reportId).toList(), meds.taken, meds.members),
      r.doctorId == null ? null : await db.doctor(r.doctorId!),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DbBuilder<_Detail?>(
      load: _load,
      builder: (context, d) {
        if (d == null) return const Scaffold();
        final theme = Theme.of(context);
        final r = d.report;

        final byPanel = <String, List<TestResult>>{};
        for (final x in d.results) {
          byPanel.putIfAbsent(panelFor(x.testKey), () => []).add(x);
        }
        for (final list in byPanel.values) {
          list.sort((a, b) => compareTestKeys(a.testKey, b.testKey));
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(r.title),
            actions: [
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_rounded),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReportEditorScreen.edit(member: d.member, report: r, existingResults: d.results, attachments: d.attachments),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  final ok = await confirm(context, title: 'Delete this report?', message: 'Its values and original files will be removed from this device.');
                  if (!ok) return;
                  await AppDb.instance.deleteReport(r.id);
                  if (context.mounted) Navigator.pop(context);
                },
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ContentWidth(
            maxWidth: 760,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
              children: [
                Text(
                  [d.member.name, if (r.type != DocType.lab) r.type.label, dateFmt.format(r.date), ?r.lab].join(' · '),
                  style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (d.doctor != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: DoctorAvatar(d.doctor!, radius: 18),
                    title: Text(d.doctor!.name),
                    subtitle: d.doctor!.details.isEmpty ? null : Text(d.doctor!.details),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DoctorDetailScreen(doctorId: d.doctor!.id))),
                  ),
                if (r.followUp != null)
                  ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.event_rounded), title: Text('Follow-up ${dateFmt.format(r.followUp!)}')),
                const SizedBox(height: 16),
                if (d.attachments.isNotEmpty) ...[
                  AttachmentStrip(attachments: d.attachments),
                  const SizedBox(height: 16),
                ],
                for (final panel in panelOrder.where(byPanel.containsKey)) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4),
                    child: Text(panel, style: theme.textTheme.titleSmall),
                  ),
                  Card(
                    child: Column(children: [
                      for (final x in byPanel[panel]!) _ResultTile(result: x, member: d.member),
                    ]),
                  ),
                ],
                if (r.type == DocType.prescription || d.meds.medications.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 8),
                    child: Row(children: [
                      Expanded(child: Text('Medicines', style: theme.textTheme.titleSmall)),
                      TextButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => MedicationFormScreen(member: d.member, reportId: r.id)),
                        ),
                        icon: const Icon(Icons.add_rounded),
                        label: const Text('Add medicine'),
                      ),
                    ]),
                  ),
                  if (d.meds.medications.isEmpty)
                    Text('Add the medicines from this prescription to get dose reminders.', style: theme.textTheme.bodyMedium),
                  for (final m in d.meds.medications)
                    Padding(padding: const EdgeInsets.only(bottom: 10), child: MedicationCard(medication: m, state: d.meds, member: d.member)),
                ],
                if (r.notes != null) ...[
                  const SizedBox(height: 20),
                  Text('Notes', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  SelectableText(r.notes!),
                ],
                if (r.extractedBy != null) ...[
                  const SizedBox(height: 20),
                  Text('Read by ${r.extractedBy} and reviewed by you.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result, required this.member});
  final TestResult result;
  final Member member;

  @override
  Widget build(BuildContext context) {
    final range = formatRange(result.refLow, result.refHigh);
    return ResultTile(
      result: result,
      title: result.testName,
      subtitle: range.isEmpty ? null : 'Range $range',
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => TrendScreen(member: member, testKey: result.testKey, testName: result.testName)),
      ),
    );
  }
}
