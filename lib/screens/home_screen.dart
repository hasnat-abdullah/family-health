import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/medicines.dart';
import 'backup_screen.dart';
import 'doctors_screen.dart';
import 'import_flow.dart';
import 'member_form_screen.dart';
import 'member_screen.dart';
import 'report_detail_screen.dart';
import 'trend_screen.dart';

class _FollowUp {
  _FollowUp(this.report, this.member, this.doctor);
  final Report report;
  final Member? member;
  final Doctor? doctor;
}

class _HomeData {
  _HomeData(this.members, this.meds, this.followUps);
  final List<MemberSummary> members;
  final MedState meds;
  final List<_FollowUp> followUps;
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static Future<_HomeData> _load() async {
    final db = AppDb.instance;
    final members = await db.memberSummaries();
    final byId = {for (final s in members) s.member.id: s.member};
    return _HomeData(members, await MedState.load(), [
      for (final r in await db.upcomingFollowUps())
        _FollowUp(r, byId[r.memberId], r.doctorId == null ? null : await db.doctor(r.doctorId!)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Family Health'),
        actions: [
          IconButton(
            tooltip: 'Import a document',
            icon: const Icon(Icons.document_scanner_outlined),
            onPressed: () => smartImport(context),
          ),
          IconButton(
            tooltip: 'Doctors',
            icon: const Icon(Icons.medical_services_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DoctorsScreen())),
          ),
          IconButton(
            tooltip: 'Security & backup',
            icon: const Icon(Icons.shield_outlined),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BackupScreen())),
          ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MemberFormScreen())),
        icon: const Icon(Icons.person_add_alt_1_rounded),
        label: const Text('Add member'),
      ),
      body: DbBuilder<_HomeData>(
        load: _load,
        builder: (context, data) {
          final members = data.members;
          if (members.isEmpty) {
            return EmptyState(
              icon: Icons.family_restroom_rounded,
              title: 'Start with your family',
              message: 'Add a profile for yourself and each family member. Each person gets their own reports, documents, medicines and trend charts.',
              action: FilledButton.icon(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MemberFormScreen())),
                icon: const Icon(Icons.person_add_alt_1_rounded),
                label: const Text('Add first member'),
              ),
            );
          }
          final flagged = members.where((s) => s.attention.isNotEmpty).toList();
          final hasDoses = data.meds.todaySlots().isNotEmpty;

          return LayoutBuilder(
            builder: (context, c) {
              final columns = (c.maxWidth / 340).floor().clamp(1, 4);
              // Dashboard cards sit side by side on wide screens.
              final dashWide = c.maxWidth >= 900 && hasDoses && flagged.isNotEmpty;
              Widget attention(MemberSummary s) => AttentionCard(
                title: s.member.name,
                leading: MemberAvatar(s.member, radius: 12),
                items: s.attention,
                onHeaderTap: () =>
                    Navigator.push(context, MaterialPageRoute(builder: (_) => MemberScreen(memberId: s.member.id))),
                onTap: (r) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TrendScreen(member: s.member, testKey: r.testKey, testName: r.testName),
                  ),
                ),
              );
              final dashboard = <Widget>[
                if (hasDoses) TodayDoses(state: data.meds, showMember: members.length > 1, collapsedRows: 4),
                if (data.followUps.isNotEmpty) _FollowUpsCard(data.followUps),
                for (final s in flagged) attention(s),
              ];

              return CustomScrollView(
                slivers: [
                  if (dashboard.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      sliver: SliverToBoxAdapter(
                        child: dashWide
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: dashboard.first),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      children: [
                                        for (final w in dashboard.skip(1))
                                          Padding(padding: const EdgeInsets.only(bottom: 12), child: w),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                children: [
                                  for (final w in dashboard)
                                    Padding(padding: const EdgeInsets.only(bottom: 12), child: w),
                                ],
                              ),
                      ),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    sliver: SliverToBoxAdapter(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Text('Family', style: Theme.of(context).textTheme.titleSmall),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                    // Cards size to their content, so long names and large text never clip.
                    sliver: SliverToBoxAdapter(
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final m in members)
                            SizedBox(width: (c.maxWidth - 32 - 12 * (columns - 1)) / columns, child: _MemberCard(m)),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _FollowUpsCard extends StatelessWidget {
  const _FollowUpsCard(this.items);
  final List<_FollowUp> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.event_rounded, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text('Follow-ups', style: theme.textTheme.titleSmall),
                ],
              ),
            ),
            for (final f in items.take(4))
              ListTile(
                dense: true,
                leading: f.member == null ? null : MemberAvatar(f.member!, radius: 14),
                title: Text(dateFmt.format(f.report.followUp!)),
                subtitle: Text([?f.member?.name, f.report.title, ?f.doctor?.name].join(' · ')),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => ReportDetailScreen(reportId: f.report.id)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard(this.summary);
  final MemberSummary summary;

  @override
  Widget build(BuildContext context) {
    final m = summary.member;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final details = [?m.relation, if (m.age != null) '${m.age} yrs', ?m.bloodGroup].join(' · ');
    final outOfRange = summary.attention.length;

    return Card(
      key: ValueKey('member-card-${m.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MemberScreen(memberId: m.id))),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              MemberAvatar(m, radius: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.name, style: theme.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (details.isNotEmpty) Text(details, style: muted, maxLines: 1),
                    const SizedBox(height: 6),
                    Text(
                      [
                        summary.reportCount == 0
                            ? 'No records yet'
                            : '${summary.reportCount} record${summary.reportCount == 1 ? '' : 's'}',
                        if (summary.activeMedicines > 0)
                          '${summary.activeMedicines} medicine${summary.activeMedicines == 1 ? '' : 's'}',
                      ].join(' · '),
                      style: muted,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (outOfRange > 0)
                Tooltip(
                  message: '$outOfRange test(s) out of range in the latest results',
                  child: Chip(
                    avatar: const Icon(Icons.error_outline_rounded, size: 16, color: StatusColors.critical),
                    label: Text('$outOfRange'),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
