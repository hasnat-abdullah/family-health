import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../screens/medication_form_screen.dart';
import 'common.dart';

/// Medicines plus which doses were taken, for one member or the whole family.
class MedState {
  MedState(this.medications, this.taken, this.members);
  final List<Medication> medications;
  final Map<String, Set<String>> taken;
  final Map<String, Member> members;

  static Future<MedState> load({String? memberId}) async {
    final db = AppDb.instance;
    return MedState(await db.medications(memberId: memberId), await db.takenDoses(memberId: memberId), {
      for (final m in await db.members()) m.id: m,
    });
  }

  bool isTaken(Medication m, DateTime slot) => taken[m.id]?.contains(DoseLog.slotKey(slot)) ?? false;

  /// Doses taken so far within the course.
  int takenCount(Medication m) => taken[m.id]?.length ?? 0;

  List<(DateTime, Medication)> todaySlots() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final end = start.add(const Duration(days: 1)).subtract(const Duration(minutes: 1));
    return [
      for (final m in medications)
        for (final s in m.slotsBetween(start, end)) (s, m),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
  }
}

/// Checklist of today's doses. Tapping marks a dose taken (and stops its reminder).
class TodayDoses extends StatefulWidget {
  const TodayDoses({super.key, required this.state, this.showMember = false, this.collapsedRows});
  final MedState state;
  final bool showMember;

  /// When set, only this many not-yet-taken doses show until expanded.
  final int? collapsedRows;

  @override
  State<TodayDoses> createState() => _TodayDosesState();
}

class _TodayDosesState extends State<TodayDoses> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final showMember = widget.showMember;
    final slots = state.todaySlots();
    if (slots.isEmpty) return const SizedBox.shrink();
    final limit = widget.collapsedRows;
    final collapsed = limit != null && !_expanded;
    final visible = collapsed ? slots.where((s) => !state.isTaken(s.$2, s.$1)).take(limit).toList() : slots;
    final hidden = slots.length - visible.length;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final done = slots.where((s) => state.isTaken(s.$2, s.$1)).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.medication_rounded, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(child: Text("Today's medicines", style: theme.textTheme.titleSmall)),
                  Text(
                    '$done of ${slots.length} taken',
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            for (final (slot, m) in visible)
              Builder(
                builder: (context) {
                  final taken = state.isTaken(m, slot);
                  final overdue = !taken && slot.isBefore(now.subtract(const Duration(minutes: 30)));
                  final member = state.members[m.memberId];
                  return CheckboxListTile(
                    dense: true,
                    value: taken,
                    onChanged: (v) => AppDb.instance.setTaken(m, slot, v ?? false),
                    secondary: SizedBox(
                      width: 64,
                      child: Text(
                        TimeOfDay.fromDateTime(slot).format(context),
                        style: theme.textTheme.labelLarge?.copyWith(color: overdue ? theme.colorScheme.error : null),
                      ),
                    ),
                    title: Text(
                      '${m.name}${m.dose == null ? '' : ' · ${m.dose}'}',
                      style: taken ? const TextStyle(decoration: TextDecoration.lineThrough) : null,
                    ),
                    subtitle: Text(
                      [
                        if (showMember && member != null) member.name,
                        ?m.instructions,
                        if (overdue) 'Not marked yet',
                      ].join(' · '),
                    ),
                  );
                },
              ),
            if (limit != null && (hidden > 0 || _expanded))
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(_expanded ? 'Show less' : 'Show all $hidden more (incl. taken)'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class MedicationCard extends StatelessWidget {
  const MedicationCard({super.key, required this.medication, required this.state, required this.member});
  final Medication medication;
  final MedState state;
  final Member member;

  @override
  Widget build(BuildContext context) {
    final m = medication;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final today = DateTime.now();
    final finished = m.isFinishedOn(today);
    final notStarted = !finished && !m.isActiveOn(today);
    final total = m.totalDoses;
    final taken = state.takenCount(m);

    final status = finished
        ? 'Finished ${dateFmt.format(m.endDate!)}'
        : notStarted
        ? 'Starts ${dateFmt.format(m.startDate)}'
        : m.days == null
        ? 'Ongoing since ${dateFmt.format(m.startDate)}'
        : 'Day ${m.dayNumber(today)} of ${m.days} · ends ${dateFmt.format(m.endDate!)}';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MedicationFormScreen(member: member, medication: m),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('${m.name}${m.dose == null ? '' : ' · ${m.dose}'}', style: theme.textTheme.titleMedium),
                  ),
                  if (m.reminders && !finished)
                    Tooltip(
                      message: 'Reminders on',
                      child: Icon(Icons.notifications_active_outlined, size: 18, color: theme.colorScheme.primary),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text([m.times.map((t) => formatTime(context, t)).join(', '), ?m.instructions].join(' · '), style: muted),
              const SizedBox(height: 2),
              Text(status, style: muted),
              if (total != null) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(value: total == 0 ? 0 : (taken / total).clamp(0, 1), minHeight: 6),
                ),
                const SizedBox(height: 4),
                Text('$taken of $total doses taken', style: muted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
