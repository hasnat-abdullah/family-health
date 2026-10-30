import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/models.dart';
import '../widgets/common.dart';
import 'report_detail_screen.dart';

class DoctorAvatar extends StatelessWidget {
  const DoctorAvatar(this.doctor, {super.key, this.radius = 22});
  final Doctor doctor;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.tertiaryContainer,
      child: Text(
        doctor.initials,
        style: TextStyle(color: scheme.onTertiaryContainer, fontWeight: FontWeight.w600, fontSize: radius * 0.75),
      ),
    );
  }
}

/// Everyone the family consults.
class DoctorsScreen extends StatelessWidget {
  const DoctorsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void add() => Navigator.push(context, MaterialPageRoute(builder: (_) => const DoctorFormScreen()));
    return Scaffold(
      appBar: AppBar(title: const Text('Doctors')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add doctor'),
      ),
      body: DbBuilder<List<DoctorSummary>>(
        load: AppDb.instance.doctorSummaries,
        builder: (context, doctors) {
          if (doctors.isEmpty) {
            return EmptyState(
              icon: Icons.medical_services_outlined,
              title: 'No doctors yet',
              message: 'Add the doctors your family sees. Link a prescription or report to a doctor, and everything from them is kept together, for each person they treat.',
              action: FilledButton.icon(
                onPressed: add,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Add doctor'),
              ),
            );
          }
          return ContentWidth(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
              children: [
                for (final s in doctors)
                  ListTile(
                    key: ValueKey('doctor-${s.doctor.id}'),
                    leading: DoctorAvatar(s.doctor),
                    title: Text(s.doctor.name),
                    subtitle: Text(
                      [
                        if (s.doctor.details.isNotEmpty) s.doctor.details,
                        s.recordCount == 0
                            ? 'No records yet'
                            : '${s.recordCount} record${s.recordCount == 1 ? '' : 's'}',
                        if (s.lastVisit != null) 'last ${dateFmt.format(s.lastVisit!)}',
                      ].join(' · '),
                    ),
                    trailing: s.patients.isEmpty ? null : _Patients(s.patients),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => DoctorDetailScreen(doctorId: s.doctor.id)),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Patients extends StatelessWidget {
  const _Patients(this.patients);
  final List<Member> patients;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final m in patients.take(3))
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Tooltip(message: m.name, child: MemberAvatar(m, radius: 13)),
        ),
      if (patients.length > 3) Padding(padding: const EdgeInsets.only(left: 4), child: Text('+${patients.length - 3}')),
    ],
  );
}

class _DoctorData {
  _DoctorData(this.doctor, this.reports, this.members);
  final Doctor doctor;
  final List<Report> reports;
  final Map<String, Member> members;
}

/// One doctor's prescriptions and reports, for everyone they see.
class DoctorDetailScreen extends StatefulWidget {
  const DoctorDetailScreen({super.key, required this.doctorId});
  final String doctorId;

  @override
  State<DoctorDetailScreen> createState() => _DoctorDetailScreenState();
}

class _DoctorDetailScreenState extends State<DoctorDetailScreen> {
  String? _memberFilter;

  Future<_DoctorData?> _load() async {
    final db = AppDb.instance;
    final d = await db.doctor(widget.doctorId);
    if (d == null) return null;
    return _DoctorData(d, await db.reportsForDoctor(d.id), {for (final m in await db.members()) m.id: m});
  }

  @override
  Widget build(BuildContext context) => DbBuilder<_DoctorData?>(
    load: _load,
    builder: (context, data) {
      if (data == null) return const Scaffold();
      final d = data.doctor;
      final theme = Theme.of(context);
      final patients = [for (final id in data.reports.map((r) => r.memberId).toSet()) ?data.members[id]];
      final shown = data.reports.where((r) => _memberFilter == null || r.memberId == _memberFilter).toList();
      int? year;
      return Scaffold(
        appBar: AppBar(
          title: Text(d.name, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_rounded),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DoctorFormScreen(doctor: d))),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                final ok = await confirm(
                  context,
                  title: 'Delete ${d.name}?',
                  message: 'Only the doctor\'s page is removed. Their prescriptions and reports stay with each family member.',
                );
                if (!ok) return;
                await AppDb.instance.deleteDoctor(d.id);
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
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: DoctorAvatar(d, radius: 28),
                title: Text(d.name, style: theme.textTheme.titleMedium),
                subtitle: d.details.isEmpty ? null : Text(d.details),
              ),
              if (d.phone != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.phone_outlined),
                  title: SelectableText(d.phone!),
                ),
              if (d.notes != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.notes_rounded),
                  title: SelectableText(d.notes!),
                ),
              if (patients.length > 1)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      FilterChip(
                        label: const Text('Everyone'),
                        selected: _memberFilter == null,
                        onSelected: (_) => setState(() => _memberFilter = null),
                      ),
                      for (final m in patients)
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: FilterChip(
                            avatar: MemberAvatar(m, radius: 11),
                            label: Text(m.name),
                            selected: _memberFilter == m.id,
                            onSelected: (_) => setState(() => _memberFilter = _memberFilter == m.id ? null : m.id),
                          ),
                        ),
                    ],
                  ),
                ),
              if (data.reports.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'Nothing linked yet. Choose this doctor when you add a prescription or report.',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final r in shown) ...[
                if (r.date.year != year)
                  Builder(
                    builder: (context) {
                      year = r.date.year;
                      return Padding(
                        padding: const EdgeInsets.only(top: 20, bottom: 4),
                        child: Text('$year', style: theme.textTheme.titleSmall),
                      );
                    },
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Icon(docIcon(r.type))),
                  title: Text(r.title),
                  subtitle: Text([dateFmt.format(r.date), r.type.label, ?data.members[r.memberId]?.name].join(' · ')),
                  trailing: data.members[r.memberId] == null
                      ? null
                      : MemberAvatar(data.members[r.memberId]!, radius: 13),
                  onTap: () =>
                      Navigator.push(context, MaterialPageRoute(builder: (_) => ReportDetailScreen(reportId: r.id))),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

/// Create or edit a doctor. Pops with the saved [Doctor].
class DoctorFormScreen extends StatefulWidget {
  const DoctorFormScreen({super.key, this.doctor});
  final Doctor? doctor;

  @override
  State<DoctorFormScreen> createState() => _DoctorFormScreenState();
}

class _DoctorFormScreenState extends State<DoctorFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.doctor?.name);
  late final _specialty = TextEditingController(text: widget.doctor?.specialty);
  late final _hospital = TextEditingController(text: widget.doctor?.hospital);
  late final _phone = TextEditingController(text: widget.doctor?.phone);
  late final _notes = TextEditingController(text: widget.doctor?.notes);

  static String? _opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final d = widget.doctor ?? Doctor(name: '');
    d
      ..name = _name.text.trim()
      ..specialty = _opt(_specialty)
      ..hospital = _opt(_hospital)
      ..phone = _opt(_phone)
      ..notes = _opt(_notes);
    await AppDb.instance.saveDoctor(d);
    if (mounted) Navigator.pop(context, d);
  }

  @override
  Widget build(BuildContext context) {
    const gap = SizedBox(height: 16);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.doctor == null ? 'New doctor' : 'Edit doctor'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(onPressed: _save, child: const Text('Save')),
          ),
        ],
      ),
      body: ContentWidth(
        maxWidth: 560,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _name,
                autofocus: widget.doctor == null,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Dr. Abdul Karim'),
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a name' : null,
              ),
              gap,
              TextFormField(
                controller: _specialty,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Specialty', hintText: 'e.g. Haematology'),
              ),
              gap,
              TextFormField(
                controller: _hospital,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(labelText: 'Hospital / chamber'),
              ),
              gap,
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
              gap,
              TextFormField(
                controller: _notes,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  hintText: 'Chamber hours, serial number…',
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
