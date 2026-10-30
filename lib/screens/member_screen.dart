import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/lab_catalog.dart';
import '../data/models.dart';
import '../data/storage.dart';
import '../services/ai/ai_config.dart';
import '../services/csv_service.dart';
import '../services/file_io.dart';
import '../widgets/common.dart';
import '../widgets/medicines.dart';
import '../widgets/trend_chart.dart';
import 'backup_screen.dart';
import 'import_flow.dart';
import 'medication_form_screen.dart';
import 'member_form_screen.dart';
import 'report_detail_screen.dart';
import 'report_editor_screen.dart';
import 'trend_screen.dart';

class _MemberData {
  _MemberData(this.member, this.reports, this.results, this.attention, this.meds, this.fileCounts, this.doctors);
  final Member member;
  final List<Report> reports;
  final List<TestResult> results;
  final List<TestResult> attention;
  final MedState meds;
  final Map<String, int> fileCounts;
  final Map<String, Doctor> doctors;
}

class MemberScreen extends StatelessWidget {
  const MemberScreen({super.key, required this.memberId});
  final String memberId;

  Future<_MemberData?> _load() async {
    final db = AppDb.instance;
    final m = await db.member(memberId);
    if (m == null) return null;
    return _MemberData(
      m,
      await db.reports(memberId),
      await db.resultsForMember(memberId),
      await db.attention(memberId),
      await MedState.load(memberId: memberId),
      await db.attachmentCounts(memberId),
      {for (final d in await db.doctors()) d.id: d},
    );
  }

  @override
  Widget build(BuildContext context) {
    return DbBuilder<_MemberData?>(
      load: _load,
      builder: (context, data) {
        if (data == null) return const Scaffold();
        final m = data.member;
        final activeMeds = data.meds.medications.where((x) => !x.isFinishedOn(DateTime.now())).length;
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: Row(
                children: [
                  MemberAvatar(m, radius: 16),
                  const SizedBox(width: 12),
                  Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis)),
                ],
              ),
              actions: [
                _MemberMenu(member: m),
                const SizedBox(width: 4),
              ],
              bottom: TabBar(
                // On phones, tabs size to their labels (and scroll) so counts are never cut off.
                isScrollable: MediaQuery.sizeOf(context).width < 600,
                tabAlignment: MediaQuery.sizeOf(context).width < 600 ? TabAlignment.start : TabAlignment.fill,
                tabs: [
                  const Tab(text: 'Health'),
                  Tab(text: 'Documents (${data.reports.length})'),
                  Tab(text: activeMeds == 0 ? 'Medicines' : 'Medicines ($activeMeds)'),
                ],
              ),
            ),
            floatingActionButton: FloatingActionButton.extended(
              onPressed: () => showAddReportSheet(context, m),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add'),
            ),
            body: TabBarView(
              children: [
                _TrendsTab(data: data),
                _ReportsTab(data: data),
                _MedicinesTab(data: data),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- Add report

Future<void> showAddReportSheet(BuildContext context, Member member) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetHeader('Lab report — values are read and charted'),
            if (isMobile) const _SheetOption('camera', Icons.photo_camera_rounded, 'Take a photo', 'Photograph a paper report'),
            if (isMobile)
              const _SheetOption('photos', Icons.photo_library_rounded, 'Choose from photos', 'A picture of a report you already have'),
            _SheetOption(
              'files',
              Icons.upload_file_rounded,
              isMobile ? 'Choose a PDF or image file' : 'Import PDF or image',
              'Lab PDFs are read exactly; scans and photos via on-device OCR',
            ),
            const _SheetOption('csv', Icons.table_chart_rounded, 'Import from CSV', 'One row per test, or one row per date'),
            const _SheetOption('manual', Icons.edit_note_rounded, 'Enter values manually', 'e.g. your monthly CBC'),
            const Divider(),
            const _SheetHeader('Other records'),
            const _SheetOption(
              'doc:prescription',
              Icons.receipt_long_outlined,
              'Prescription',
              'Store it, then add its medicines with reminders',
            ),
            const _SheetOption(
              'doc:other',
              Icons.folder_open_rounded,
              'Other document',
              'X-ray, scan, discharge summary, vaccination card…',
            ),
            const _SheetOption('medicine', Icons.medication_rounded, 'Medicine reminder', 'Without a prescription document'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'manual':
      await Navigator.push(context, MaterialPageRoute(builder: (_) => ReportEditorScreen.create(member: member)));
    case 'csv':
      await _importCsv(context, member);
    case 'medicine':
      await Navigator.push(context, MaterialPageRoute(builder: (_) => MedicationFormScreen(member: member)));
    case 'doc:prescription' || 'doc:other':
      await _addDocument(context, member, choice == 'doc:prescription' ? DocType.prescription : DocType.other);
    default:
      final picked = switch (choice) {
        'camera' => [?await FileIO.takePhoto()],
        'photos' => await FileIO.pickImages(),
        _ => await FileIO.pickReports(),
      };
      if (picked.isNotEmpty && context.mounted) await ingestFiles(context, member: member, picked: picked);
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
  );
}

/// Documents are stored as-is (no value extraction).
Future<void> _addDocument(BuildContext context, Member member, DocType type) async {
  final source = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isMobile) const _SheetOption('camera', Icons.photo_camera_rounded, 'Take a photo', ''),
          if (isMobile) const _SheetOption('photos', Icons.photo_library_rounded, 'Choose from photos', ''),
          const _SheetOption('files', Icons.upload_file_rounded, 'Choose a PDF or image file', ''),
          const _SheetOption('none', Icons.edit_note_rounded, 'No file — just notes', ''),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  final picked = switch (source) {
    'camera' => [?await FileIO.takePhoto()],
    'photos' => await FileIO.pickImages(),
    'files' => await FileIO.pickReports(),
    _ => <Picked>[],
  };
  if (source != 'none' && picked.isEmpty) return;
  if (picked.isNotEmpty && AiSettings.instance.enabled) {
    if (context.mounted) await ingestFiles(context, member: member, picked: picked, type: type);
    return;
  }
  final reportId = newId();
  final attachments = [for (final f in picked) await FileStore.instance.importFile(f.file, reportId: reportId, originalName: f.name)];
  await FileIO.discardPlainCopies(picked);
  if (!context.mounted) return;
  await Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ReportEditorScreen.create(member: member, reportId: reportId, attachments: attachments, type: type),
    ),
  );
}

class _SheetOption extends StatelessWidget {
  const _SheetOption(this.value, this.icon, this.title, this.subtitle);
  final String value;
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle.isEmpty ? null : Text(subtitle),
    onTap: () => Navigator.pop(context, value),
  );
}

Future<void> _importCsv(BuildContext context, Member member) async {
  final picked = await FileIO.pickOne(['csv', 'txt']);
  if (picked == null || !context.mounted) return;
  try {
    final result = CsvService.parse(await picked.file.readAsString(), member);
    if (!context.mounted) return;
    if (result.reports.isEmpty) {
      showMessage(context, 'No results found in that CSV.');
      return;
    }
    final ok = await confirm(
      context,
      title: 'Import CSV',
      message:
          'Add ${result.resultCount} results in ${result.reports.length} report(s) to ${member.name}?'
          '${result.skippedRows > 0 ? '\n\n${result.skippedRows} row(s) without a date, test or value will be skipped.' : ''}',
      action: 'Import',
    );
    if (!ok) return;
    for (final (report, results) in result.reports) {
      await AppDb.instance.saveReport(report, results, const []);
    }
    if (context.mounted) showMessage(context, 'Imported ${result.resultCount} results.');
  } on FormatException catch (e) {
    if (context.mounted) showMessage(context, e.message);
  }
}

// ---------------------------------------------------------------- Menu

class _MemberMenu extends StatelessWidget {
  const _MemberMenu({required this.member});
  final Member member;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    onSelected: (v) async {
      switch (v) {
        case 'edit':
          await Navigator.push(context, MaterialPageRoute(builder: (_) => MemberFormScreen(member: member)));
        case 'export':
          await exportBackupFlow(context, member: member);
        case 'csv':
          final ok = await confirm(
            context,
            title: 'Export unencrypted CSV?',
            message: 'Spreadsheet files cannot be password-protected. Anyone who gets this file can read the results.',
            action: 'Export CSV',
          );
          if (!ok || !context.mounted) return;
          final db = AppDb.instance;
          final csv = CsvService.export([member], await db.reports(member.id), await db.resultsForMember(member.id));
          if (context.mounted) {
            await FileIO.saveOrShare(context, '${_slug(member.name)}-results.csv', utf8.encode(csv), mime: 'text/csv');
          }
        case 'delete':
          final ok = await confirm(
            context,
            title: 'Delete ${member.name}?',
            message: 'This permanently removes their profile, all reports and the original files from this device. Export a backup first if you might need them.',
          );
          if (ok) {
            await AppDb.instance.deleteMember(member.id);
            if (context.mounted) Navigator.pop(context);
          }
      }
    },
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: 'edit',
        child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Edit profile')),
      ),
      PopupMenuItem(
        value: 'export',
        child: ListTile(leading: Icon(Icons.lock_rounded), title: Text('Export encrypted backup')),
      ),
      PopupMenuItem(
        value: 'csv',
        child: ListTile(leading: Icon(Icons.table_chart_rounded), title: Text('Export results as CSV (unencrypted)')),
      ),
      PopupMenuDivider(),
      PopupMenuItem(
        value: 'delete',
        child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Delete member')),
      ),
    ],
  );
}

String _slug(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');

// ---------------------------------------------------------------- Trends tab

class _TestSeries {
  _TestSeries(this.key, this.results);
  final String key;
  final List<TestResult> results; // oldest first
  TestResult get latest => results.last;
  List<TestResult> get numeric => results.where((r) => r.value != null).toList();
}

class _TrendsTab extends StatelessWidget {
  const _TrendsTab({required this.data});
  final _MemberData data;

  @override
  Widget build(BuildContext context) {
    final todayDoses = data.meds.todaySlots().isNotEmpty;
    if (data.results.isEmpty && !todayDoses) {
      return EmptyState(
        icon: Icons.show_chart_rounded,
        title: 'No results yet',
        message: 'Add a report — photo, PDF, CSV or typed in — and each test will get its own trend chart here.',
        action: FilledButton.icon(
          onPressed: () => showAddReportSheet(context, data.member),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add report'),
        ),
      );
    }

    final byKey = <String, List<TestResult>>{};
    for (final r in data.results) {
      byKey.putIfAbsent(r.testKey, () => []).add(r);
    }
    final byPanel = <String, List<_TestSeries>>{};
    for (final e in byKey.entries) {
      byPanel.putIfAbsent(panelFor(e.key), () => []).add(_TestSeries(e.key, e.value));
    }
    for (final list in byPanel.values) {
      list.sort((a, b) => compareTestKeys(a.key, b.key));
    }
    final panels = panelOrder.where(byPanel.containsKey).toList();

    return LayoutBuilder(
      builder: (context, c) {
        final columns = (c.maxWidth / 320).floor().clamp(1, 4);
        Widget top(Widget child) => SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          sliver: SliverToBoxAdapter(child: child),
        );
        return CustomScrollView(
          slivers: [
            if (data.attention.isNotEmpty)
              top(
                AttentionCard(
                  items: data.attention,
                  onTap: (r) => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TrendScreen(member: data.member, testKey: r.testKey, testName: r.testName),
                    ),
                  ),
                ),
              ),
            if (todayDoses) top(TodayDoses(state: data.meds)),
            for (final panel in panels) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                sliver: SliverToBoxAdapter(child: Text(panel, style: Theme.of(context).textTheme.titleSmall)),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    // Room for the text (which grows with the text-size setting) plus the chart.
                    mainAxisExtent: 84 + MediaQuery.textScalerOf(context).scale(68),
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _TrendCard(member: data.member, series: byPanel[panel]![i]),
                    childCount: byPanel[panel]!.length,
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        );
      },
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.member, required this.series});
  final Member member;
  final _TestSeries series;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final latest = series.latest;
    final numeric = series.numeric;
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    String? delta;
    if (numeric.length >= 2 && latest.value != null) {
      final d = numeric.last.value! - numeric[numeric.length - 2].value!;
      delta = d == 0 ? 'no change' : '${d > 0 ? '▲' : '▼'} ${formatNumber(d.abs())} since last';
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      color: abnormalTint(context, latest.flag),
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TrendScreen(member: member, testKey: series.key, testName: latest.testName),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(latest.testName, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(formatValue(latest), style: valueStyle(context, latest.flag, base: theme.textTheme.headlineSmall)),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(latest.unit ?? '', style: muted, overflow: TextOverflow.ellipsis),
                  ),
                  const SizedBox(width: 8),
                  FlagBadge(latest.flag),
                ],
              ),
              Text([dateFmt.format(latest.date), ?delta].join(' · '), style: muted, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Expanded(child: numeric.length >= 2 ? TrendChart(results: numeric, compact: true) : const SizedBox()),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- Documents tab

class _ReportsTab extends StatefulWidget {
  const _ReportsTab({required this.data});
  final _MemberData data;

  @override
  State<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<_ReportsTab> {
  DocType? _filter;
  String? _doctorFilter;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data.reports.isEmpty) {
      return EmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No documents yet',
        message: 'Keep lab reports, prescriptions, scans and other papers here — the originals are stored with them.',
        action: FilledButton.icon(
          onPressed: () => showAddReportSheet(context, data.member),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add'),
        ),
      );
    }
    final resultsByReport = <String, List<TestResult>>{};
    for (final r in data.results) {
      resultsByReport.putIfAbsent(r.reportId, () => []).add(r);
    }
    final present = data.reports.map((r) => r.type).toSet();
    final seen = [
      for (final id in data.reports.map((r) => r.doctorId).whereType<String>().toSet()) ?data.doctors[id],
    ];
    final shown = data.reports.where((r) => (_filter == null || r.type == _filter) && (_doctorFilter == null || r.doctorId == _doctorFilter)).toList();

    final items = <Widget>[
      if (present.length > 1)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              FilterChip(label: const Text('All'), selected: _filter == null, onSelected: (_) => setState(() => _filter = null)),
              for (final t in DocType.values.where(present.contains))
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: FilterChip(
                    avatar: Icon(docIcon(t), size: 18),
                    label: Text(t.label),
                    selected: _filter == t,
                    onSelected: (_) => setState(() => _filter = _filter == t ? null : t),
                  ),
                ),
            ],
          ),
        ),
      if (seen.isNotEmpty)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Row(
            children: [
              for (final d in seen)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    avatar: const Icon(Icons.medical_services_outlined, size: 18),
                    label: Text(d.name),
                    selected: _doctorFilter == d.id,
                    onSelected: (_) => setState(() => _doctorFilter = _doctorFilter == d.id ? null : d.id),
                  ),
                ),
            ],
          ),
        ),
    ];
    int? year;
    for (final r in shown) {
      if (r.date.year != year) {
        year = r.date.year;
        items.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text('$year', style: Theme.of(context).textTheme.titleSmall),
          ),
        );
      }
      final results = resultsByReport[r.id] ?? const [];
      final flagged = results.where((x) => isAbnormal(x.flag)).length;
      final files = data.fileCounts[r.id] ?? 0;
      items.add(
        ListTile(
          leading: CircleAvatar(child: Icon(docIcon(r.type))),
          title: Text(r.title),
          subtitle: Text(
            [
              dateFmt.format(r.date),
              if (r.type != DocType.lab) r.type.label,
              ?data.doctors[r.doctorId]?.name,
              ?r.lab,
              if (results.isNotEmpty) '${results.length} result${results.length == 1 ? '' : 's'}',
              if (files > 0) '$files file${files == 1 ? '' : 's'}',
            ].join(' · '),
          ),
          tileColor: flagged > 0 ? abnormalTint(context, ResultFlag.high) : null,
          trailing: flagged > 0
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [const FlagBadge(ResultFlag.high, compact: true), const SizedBox(width: 4), Text('$flagged out of range')],
                )
              : null,
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReportDetailScreen(reportId: r.id))),
        ),
      );
    }
    return ContentWidth(
      child: ListView(padding: const EdgeInsets.only(bottom: 96), children: items),
    );
  }
}

// ---------------------------------------------------------------- Medicines tab

class _MedicinesTab extends StatelessWidget {
  const _MedicinesTab({required this.data});
  final _MemberData data;

  @override
  Widget build(BuildContext context) {
    final meds = data.meds.medications;
    if (meds.isEmpty) {
      return EmptyState(
        icon: Icons.medication_rounded,
        title: 'No medicines',
        message:
            'Add medicines from a prescription or on their own. You will get a reminder at each dose time until the course is complete.',
        action: FilledButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MedicationFormScreen(member: data.member))),
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add medicine'),
        ),
      );
    }
    final today = DateTime.now();
    final current = meds.where((m) => !m.isFinishedOn(today)).toList();
    final past = meds.where((m) => m.isFinishedOn(today)).toList();
    final theme = Theme.of(context);
    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
      child: Text(t, style: theme.textTheme.titleSmall),
    );

    return ContentWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (data.meds.todaySlots().isNotEmpty) ...[const SizedBox(height: 8), TodayDoses(state: data.meds)],
          if (current.isNotEmpty) header('Current'),
          for (final m in current)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MedicationCard(medication: m, state: data.meds, member: data.member),
            ),
          if (past.isNotEmpty) header('Completed'),
          for (final m in past)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MedicationCard(medication: m, state: data.meds, member: data.member),
            ),
        ],
      ),
    );
  }
}
