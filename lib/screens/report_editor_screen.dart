import 'dart:async';

import 'package:flutter/material.dart';

import '../data/database.dart';
import '../data/lab_catalog.dart';
import '../data/models.dart';
import '../data/storage.dart';
import '../services/ai/ai_client.dart';
import '../services/ai/ai_config.dart';
import '../services/ai/document_prep.dart';
import '../services/ai/extraction.dart';
import '../services/file_io.dart';
import '../services/report_parser.dart';
import '../services/reminders.dart';
import '../services/report_reader.dart';
import '../theme.dart';
import '../widgets/attachment_strip.dart';
import '../widgets/common.dart';
import 'ai_settings_screen.dart';
import 'doctors_screen.dart';
import 'medication_form_screen.dart';

/// Editable result row.
class _Row {
  _Row({
    this.id,
    required this.testKey,
    required this.testName,
    String value = '',
    this.unit,
    this.refLow,
    this.refHigh,
    this.sourceLine,
    this.rangeFromReport = false,
  }) : value = TextEditingController(text: value);

  final String? id;
  String testKey;
  String testName;
  final TextEditingController value;
  String? unit;
  double? refLow;
  double? refHigh;
  final String? sourceLine;

  /// False when the range is a catalog default, which follows the member's sex.
  bool rangeFromReport;

  /// Result of comparing an AI value with the on-device reading.
  Check? check;
  String? note;

  /// Different value from the other reader, offered as a one-tap swap.
  double? alternative;

  /// Changed by hand: AI results must not overwrite it, and it no longer needs checking.
  bool touched = false;

  bool get needsReview => check != null && check!.needsReview && !touched && value.text.trim().isNotEmpty;

  double? get number => double.tryParse(value.text.trim().replaceAll(',', ''));

  ResultFlag get flag {
    final v = number;
    if (v == null || (refLow == null && refHigh == null)) return ResultFlag.unknown;
    if (refLow != null && v < refLow!) return ResultFlag.low;
    if (refHigh != null && v > refHigh!) return ResultFlag.high;
    return ResultFlag.normal;
  }
}

class ReportEditorScreen extends StatefulWidget {
  /// A new report, optionally pre-filled from files the user just imported.
  const ReportEditorScreen.create({
    super.key,
    this.member,
    this.reportId,
    this.title,
    this.date,
    this.attachments = const [],
    this.parsed = const [],
    this.notice,
    DocType this.type = DocType.lab,
    this.localLines,
    this.autoAi = false,
    this.queueLabel,
  }) : report = null,
       existingResults = const [];

  const ReportEditorScreen.edit({
    super.key,
    required this.member,
    required Report this.report,
    required this.existingResults,
    required this.attachments,
  }) : reportId = null,
       title = null,
       date = null,
       parsed = const [],
       notice = null,
       type = null,
       localLines = null,
       autoAi = false,
       queueLabel = null;

  /// Null when the document itself should say whose it is.
  final Member? member;
  final DocType? type;
  final Report? report;
  final List<TestResult> existingResults;
  final String? reportId;
  final String? title;
  final DateTime? date;
  final List<Attachment> attachments;
  final List<ParsedResult> parsed;
  final String? notice;

  /// Text already read on-device from [attachments], to avoid reading twice.
  final List<String>? localLines;

  /// Start reading with AI as soon as the screen opens.
  final bool autoAi;

  /// Position in a batch, e.g. `2 of 5`.
  final String? queueLabel;

  @override
  State<ReportEditorScreen> createState() => _ReportEditorScreenState();
}

class _ReportEditorScreenState extends State<ReportEditorScreen> {
  late final String _reportId = widget.report?.id ?? widget.reportId ?? newId();
  late DocType _type = widget.report?.type ?? widget.type ?? DocType.lab;
  late final _title = TextEditingController(
    text: widget.report?.title ?? widget.title ?? (_type == DocType.lab ? 'CBC' : _type.label),
  );
  late final _lab = TextEditingController(text: widget.report?.lab);
  late final _notes = TextEditingController(text: widget.report?.notes);
  late DateTime _date = widget.report?.date ?? widget.date ?? DateTime.now();
  late DateTime? _followUp = widget.report?.followUp;
  late Member? _member = widget.member;
  late String? _doctorId = widget.report?.doctorId;
  late String? _extractedBy = widget.report?.extractedBy;
  late List<String>? _localLines = widget.localLines;
  List<Member> _family = const [];
  List<Doctor> _doctors = const [];

  /// A doctor found on the document, created when the report is saved.
  Doctor? _newDoctor;
  final _medicines = <DraftMedicine>[];
  bool _titleEdited = false;
  final _scroll = ScrollController();

  // AI reading
  AiCancelToken? _aiCancel;
  String _aiStage = '';
  AiException? _aiError;
  ExtractionDraft? _aiDraft;
  List<String> _aiIssues = const [];
  late final List<Attachment> _attachments = [...widget.attachments];
  late final List<_Row> _rows;
  late final Set<String> _originalFiles = widget.attachments.map((a) => a.fileName).toSet();
  bool _saved = false;
  bool _reading = false;

  bool get _isNew => widget.report == null;

  @override
  void initState() {
    super.initState();
    _rows = [
      for (final r in widget.existingResults)
        _Row(
          id: r.id,
          testKey: r.testKey,
          testName: r.testName,
          value: formatValue(r) == '—' ? '' : formatValue(r),
          unit: r.unit,
          refLow: r.refLow,
          refHigh: r.refHigh,
        ),
      for (final p in widget.parsed) _rowFromParsed(p),
    ];
    if (_isNew && _type == DocType.lab && widget.parsed.isEmpty && widget.attachments.isEmpty) {
      _addPanel('Complete Blood Count');
    }
    _loadPeople();
    if (widget.autoAi) WidgetsBinding.instance.addPostFrameCallback((_) => _runAi());
  }

  Future<void> _loadPeople() async {
    final family = await AppDb.instance.members();
    final doctors = await AppDb.instance.doctors();
    if (!mounted) return;
    setState(() {
      _family = family;
      _doctors = doctors;
    });
  }

  bool get _aiRunning => _aiCancel != null;

  Future<void> _runAi() async {
    final settings = AiSettings.instance;
    if (!settings.enabled) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const AiSettingsScreen()));
      if (!settings.enabled || !mounted) return;
    }
    if (!await ensureAiConsent(context) || !mounted) return;
    final cancel = AiCancelToken();
    setState(() {
      _aiCancel = cancel;
      _aiError = null;
      _aiDraft = null;
      _aiIssues = const [];
      _aiStage = 'Preparing pages…';
    });
    try {
      final prepared = await DocumentPrep.prepare(
        _attachments,
        withImages: settings.sendImages,
        lines: _localLines,
        cancel: cancel,
      );
      if (!mounted) return;
      setState(() {
        _localLines = prepared.lines;
        _aiStage = 'Reading with ${settings.provider.label}…';
      });
      final doc = await AiReader(AiBackend.from(settings, settings.provider))
          .read(images: prepared.images, localLines: prepared.lines, cancel: cancel);
      if (!mounted) return;
      setState(() => _aiStage = 'Checking…');

      final family = await AppDb.instance.members();
      final patient = matchPatient(doc, family, _member);
      final issues = <String>[];
      if (patient.status == PatientStatus.matchesOther) {
        if (_isNew) {
          issues.add('The document names ${patient.printedName}, so this is filed under ${patient.member!.name}.');
          _member = patient.member;
        } else {
          issues.add(
            'The document names ${patient.printedName}, who looks like ${patient.member!.name}, not ${_member?.name}. Is this the right record?',
          );
        }
      } else if (patient.status == PatientStatus.noMatch) {
        issues.add(
          _member == null
              ? 'The document names ${patient.printedName}, who is not in your family list. Choose whose record this is.'
              : 'The document names ${patient.printedName}, not ${_member!.name}. Is this the right person?',
        );
      }
      if (patient.status == PatientStatus.matchesCurrent) _member ??= patient.member;
      if (prepared.skippedPages > 0) {
        issues.add(
          'Only the first ${prepared.images.length} pages were read; ${prepared.skippedPages} more were skipped. Add anything from them by hand.',
        );
      }

      final draft = ExtractionChecker(
        member: _member,
        doctors: await AppDb.instance.doctors(),
        history: _member == null ? const {} : await AppDb.instance.latestValues(_member!.id),
      ).check(doc, prepared.lines);
      if (!mounted) return;
      setState(() => _applyDraft(draft, [...issues, ...draft.issues], settings.sourceLabel));
      // The summary holds warnings such as a different patient: bring it into view.
      if (_scroll.hasClients) {
        unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut));
      }
    } on AiException catch (e) {
      if (mounted && e.kind != AiErrorKind.cancelled) {
        setState(() => _aiError = e);
        if (_scroll.hasClients) {
          unawaited(_scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut));
        }
      }
    } catch (e) {
      // The original and on-device values are safe; this must never lose the screen.
      if (mounted) setState(() => _aiError = AiException(AiErrorKind.unsupported, detail: '$e'));
    } finally {
      if (mounted) setState(() => _aiCancel = null);
    }
  }

  /// Fills the form from a checked reading. Anything typed by hand, and saved
  /// values when editing, are kept; a difference is raised on that row instead.
  void _applyDraft(ExtractionDraft d, List<String> issues, String source) {
    _aiDraft = d;
    _aiIssues = issues;
    _extractedBy = source;
    if (_isNew) {
      _type = d.type;
      if (d.title != null && !_titleEdited) _title.text = d.title!;
      if (d.date != null) _date = d.date!;
    }
    if (_lab.text.trim().isEmpty && d.lab != null) _lab.text = d.lab!;
    if (_notes.text.trim().isEmpty && d.notes != null) _notes.text = d.notes!;
    _followUp ??= d.followUp;

    final doctor = d.doctor;
    if (doctor != null && _doctorId == null && _newDoctor == null) {
      if (doctor.matchId != null) {
        _doctorId = doctor.matchId;
      } else {
        _newDoctor = Doctor(
          name: doctor.name,
          specialty: doctor.specialty,
          hospital: doctor.hospital,
          phone: doctor.phone,
        );
      }
    }

    // Unedited on-device rows are replaced: the draft already includes them.
    for (final r in _rows.where((r) => r.id == null && !r.touched && r.sourceLine != null).toList()) {
      _rows.remove(r);
      r.value.dispose();
    }
    final byKey = {for (final r in _rows) r.testKey: r};
    for (final x in d.results) {
      final existing = byKey[x.parsed.testKey];
      final fresh = _rowFromParsed(x.parsed)
        ..check = x.check
        ..note = x.note
        ..alternative = x.alternative;
      if (existing == null) {
        _rows.add(fresh);
      } else if (existing.value.text.trim().isEmpty && !existing.touched) {
        existing.value.text = fresh.value.text;
        existing
          ..unit = fresh.unit
          ..refLow = fresh.refLow
          ..refHigh = fresh.refHigh
          ..rangeFromReport = fresh.rangeFromReport
          ..check = x.check
          ..note = x.note
          ..alternative = x.alternative;
        fresh.value.dispose();
      } else {
        if (existing.number != null && x.parsed.value != null && existing.number != x.parsed.value) {
          existing
            ..touched = false
            ..check = Check.conflict
            ..note = 'The AI read ${formatNumber(x.parsed.value!)} here.'
            ..alternative = x.parsed.value;
        }
        fresh.value.dispose();
      }
    }
    _medicines
      ..clear()
      ..addAll(d.medicines);
    if (!_isNew && _medicines.isNotEmpty) _dropSavedMedicines();
  }

  /// Reading a saved prescription again shouldn't offer its medicines twice.
  Future<void> _dropSavedMedicines() async {
    final saved = (await AppDb.instance.medications(reportId: _reportId)).map((m) => m.name.toLowerCase()).toSet();
    if (mounted) setState(() => _medicines.removeWhere((m) => saved.contains(m.name.toLowerCase())));
  }

  /// A chosen person may have a different default range from the one first assumed.
  void _setMember(Member? m) {
    setState(() {
      _member = m;
      for (final r in _rows.where((r) => !r.rangeFromReport)) {
        final range = labByKey[r.testKey]?.rangeFor(m?.sex);
        if (range != null) {
          r
            ..refLow = range.low
            ..refHigh = range.high;
        }
      }
    });
  }

  _Row _rowFromParsed(ParsedResult p) {
    final defaults = labByKey[p.testKey]?.rangeFor(_member?.sex);
    final hasRange = p.refLow != null || p.refHigh != null;
    return _Row(
      testKey: p.testKey,
      testName: p.testName,
      value: p.value != null ? formatNumber(p.value!) : (p.valueText ?? ''),
      unit: p.unit,
      refLow: hasRange ? p.refLow : defaults?.low,
      refHigh: hasRange ? p.refHigh : defaults?.high,
      sourceLine: p.sourceLine,
      rangeFromReport: hasRange,
    );
  }

  _Row _rowForTest(LabTest t) {
    final range = t.rangeFor(_member?.sex);
    return _Row(testKey: t.key, testName: t.name, unit: t.unit, refLow: range?.low, refHigh: range?.high);
  }

  void _addPanel(String panel) {
    final present = _rows.map((r) => r.testKey).toSet();
    setState(() {
      _rows.addAll(labCatalog.where((t) => t.panel == panel && !present.contains(t.key)).map(_rowForTest));
    });
  }

  @override
  void dispose() {
    _aiCancel?.cancel();
    _scroll.dispose();
    for (final r in _rows) {
      r.value.dispose();
    }
    if (!_saved) {
      // Discard originals copied in for an unsaved report.
      for (final a in _attachments) {
        if (_isNew || !_originalFiles.contains(a.fileName)) FileStore.instance.delete(a.fileName);
      }
    }
    super.dispose();
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      showMessage(context, 'Please give the report a title.');
      return;
    }
    final member = _member;
    if (member == null) {
      showMessage(context, 'Choose whose record this is.');
      return;
    }
    final incomplete = _medicines
        .where((m) => m.times == null || m.times!.isEmpty || (m.days == null && !m.ongoing))
        .toList();
    if (incomplete.isNotEmpty) {
      showMessage(context, 'Set the dose times and duration for ${incomplete.first.name}, or remove it.');
      return;
    }
    final toCheck = _rows.where((r) => r.needsReview).length + _medicines.where((m) => m.check.needsReview).length;
    if (toCheck > 0) {
      final ok = await confirm(
        context,
        title: '$toCheck item${toCheck == 1 ? '' : 's'} not verified',
        message: 'The highlighted items could not be confirmed. Compare them with the original, or save and check them later.',
        action: 'Save anyway',
      );
      if (!ok || !mounted) return;
    }
    final report = widget.report ?? Report(id: _reportId, memberId: member.id, title: title, date: _date);
    report
      ..title = title
      ..type = _type
      ..date = _date
      ..lab = _lab.text.trim().isEmpty ? null : _lab.text.trim()
      ..doctorId = _doctorId
      ..followUp = _followUp
      ..extractedBy = _extractedBy
      ..notes = _notes.text.trim().isEmpty ? null : _notes.text.trim();

    final results = [
      for (final r in _rows)
        if (r.value.text.trim().isNotEmpty)
          TestResult(
            id: r.id,
            reportId: report.id,
            memberId: member.id,
            testKey: r.testKey,
            testName: r.testName,
            value: r.number,
            valueText: r.number == null ? r.value.text.trim() : null,
            unit: r.unit,
            refLow: r.refLow,
            refHigh: r.refHigh,
            date: _date,
          ),
    ];
    if (results.isEmpty && _attachments.isEmpty && report.notes == null) {
      showMessage(
        context,
        _type == DocType.lab
            ? 'Add at least one value or attach the original report.'
            : 'Attach the document or add a note.',
      );
      return;
    }
    if (_newDoctor != null) {
      await AppDb.instance.saveDoctor(_newDoctor!);
      report.doctorId = _doctorId = _newDoctor!.id;
      _newDoctor = null;
    }
    // Files removed while editing an existing report are deleted by saveReport.
    await AppDb.instance.saveReport(report, results, _attachments);
    _saved = true;
    for (final m in _medicines) {
      await AppDb.instance.saveMedication(
        Medication(
          memberId: member.id,
          reportId: report.id,
          name: m.name,
          dose: m.dose,
          times: [...m.times!]..sort(),
          startDate: _date,
          days: m.ongoing ? null : m.days,
          instructions: m.instructions,
        ),
      );
    }
    if (_medicines.isNotEmpty || _followUp != null) await Reminders.requestPermission();
    if (!mounted) return;
    if (_isNew && _type == DocType.prescription && _medicines.isEmpty && _extractedBy == null) {
      // Straight on to the medicines on this prescription, with reminders.
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => MedicationFormScreen(member: member, reportId: report.id, fromPrescription: true),
        ),
      );
    } else {
      Navigator.pop(context, true);
    }
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickFollowUp() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _followUp ?? now,
      firstDate: now,
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) setState(() => _followUp = d);
  }

  Future<void> _pickDoctor(String? value) async {
    if (value == _addDoctor) {
      final d = await Navigator.push<Doctor>(context, MaterialPageRoute(builder: (_) => const DoctorFormScreen()));
      await _loadPeople();
      if (d != null && mounted) setState(() => _doctorId = d.id);
      return;
    }
    setState(() {
      if (value != _foundDoctor) _newDoctor = null;
      _doctorId = value == _noDoctor ? null : (value == _foundDoctor ? null : value);
    });
  }

  static const _noDoctor = 'none', _addDoctor = 'add', _foundDoctor = 'found';

  Future<void> _addFiles() async {
    final picked = await FileIO.pickReports();
    if (picked.isEmpty) return;
    _localLines = null;
    setState(() => _reading = true);
    try {
      final present = _rows.map((r) => r.testKey).toSet();
      var added = 0;
      for (final f in picked) {
        final a = await FileStore.instance.importFile(f.file, reportId: _reportId, originalName: f.name);
        _attachments.add(a);
        if (_type != DocType.lab) continue;
        try {
          final parsed = ReportParser(sex: _member?.sex).parse(await ReportReader.readLines(f.file));
          for (final p in parsed.results.where((p) => !present.contains(p.testKey))) {
            _rows.add(_rowFromParsed(p));
            present.add(p.testKey);
            added++;
          }
        } catch (_) {
          // Keep the original even if it can't be read.
        }
      }
      if (mounted) showMessage(context, added > 0 ? 'Added $added values from the file.' : 'File attached.');
    } finally {
      await FileIO.discardPlainCopies(picked);
      if (mounted) setState(() => _reading = false);
    }
  }

  Future<void> _addTest() async {
    final picked = await showDialog<Object>(context: context, builder: (_) => const _TestPicker());
    if (picked == null) return;
    setState(() {
      if (picked is LabTest) {
        _rows.add(_rowForTest(picked));
      } else if (picked is String) {
        _rows.add(_Row(testKey: customKey(picked), testName: picked));
      }
    });
  }

  Future<void> _editRow(_Row row) async {
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => _RowDialog(row: row),
    );
    if (updated == true) setState(() {});
  }

  Future<bool> _confirmDiscard() async {
    final hasContent = _rows.any((r) => r.value.text.trim().isNotEmpty) || _attachments.isNotEmpty;
    if (!hasContent) return true;
    return confirm(
      context,
      title: 'Discard changes?',
      message: _isNew ? 'This report has not been saved.' : 'Your edits will be lost.',
      action: 'Discard',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) Navigator.pop(context);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            [
              ?widget.queueLabel,
              _isNew ? 'New ${_type.label.toLowerCase()}' : 'Edit ${_type.label.toLowerCase()}',
              if (_isNew) ?_member?.name,
            ].join(' · '),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
          ],
        ),
        body: ContentWidth(
          maxWidth: 760,
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 48),
            children: [
              if (widget.notice != null)
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: ListTile(
                    leading: Icon(Icons.info_outline_rounded, color: theme.colorScheme.onSecondaryContainer),
                    title: Text(widget.notice!, style: TextStyle(color: theme.colorScheme.onSecondaryContainer)),
                  ),
                ),
              ..._aiPanel(theme),
              const SizedBox(height: 12),
              if (_isNew && (widget.member == null || _aiIssues.isNotEmpty) && _family.length > 1) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('member-${_member?.id}'),
                  initialValue: _member?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Whose record is this?'),
                  items: [for (final m in _family) DropdownMenuItem(value: m.id, child: Text(m.name))],
                  onChanged: (id) => _setMember(_family.firstWhere((m) => m.id == id)),
                ),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<DocType>(
                key: ValueKey(_type),
                initialValue: _type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final t in DocType.values)
                    DropdownMenuItem(
                      value: t,
                      child: Row(
                        children: [
                          Icon(docIcon(t), size: 20),
                          const SizedBox(width: 10),
                          Flexible(child: Text(t.label, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                ],
                onChanged: (t) => setState(() => _type = t ?? _type),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _title,
                      decoration: const InputDecoration(labelText: 'Title', hintText: 'e.g. CBC, Lipid profile'),
                      onChanged: (_) => _titleEdited = true,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: InkWell(
                      onTap: _pickDate,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Report date',
                          suffixIcon: Icon(Icons.calendar_today_rounded),
                        ),
                        child: Text(dateFmt.format(_date)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _lab,
                decoration: const InputDecoration(labelText: 'Lab / hospital (optional)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('doctor-$_doctorId-${_newDoctor?.id}-${_doctors.length}'),
                initialValue: _newDoctor != null ? _foundDoctor : (_doctorId ?? _noDoctor),
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Doctor (optional)',
                  prefixIcon: Icon(Icons.medical_services_outlined),
                ),
                items: [
                  const DropdownMenuItem(value: _noDoctor, child: Text('None')),
                  for (final d in _doctors)
                    DropdownMenuItem(
                      value: d.id,
                      child: Text(d.name, overflow: TextOverflow.ellipsis),
                    ),
                  if (_newDoctor != null)
                    DropdownMenuItem(
                      value: _foundDoctor,
                      child: Text('New: ${_newDoctor!.name}', overflow: TextOverflow.ellipsis),
                    ),
                  const DropdownMenuItem(value: _addDoctor, child: Text('Add a doctor…')),
                ],
                onChanged: _pickDoctor,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _type == DocType.lab ? 'Original report' : 'Document',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (_reading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  if (_attachments.isNotEmpty && !_aiRunning)
                    TextButton.icon(
                      onPressed: _reading ? null : _runAi,
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: const Text('Read with AI'),
                    ),
                  TextButton.icon(
                    onPressed: _reading ? null : _addFiles,
                    icon: const Icon(Icons.attach_file_rounded),
                    label: const Text('Attach'),
                  ),
                ],
              ),
              AttachmentStrip(
                attachments: _attachments,
                onRemove: (a) => setState(() {
                  _attachments.remove(a);
                  _localLines = null;
                }),
              ),
              if (_type == DocType.lab || _rows.isNotEmpty) ..._resultsSection(theme),
              if (_medicines.isNotEmpty) ..._medicinesSection(theme),
              if (_type != DocType.lab || _followUp != null) ...[
                const SizedBox(height: 20),
                InkWell(
                  onTap: _pickFollowUp,
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Follow-up (optional)',
                      suffixIcon: _followUp == null
                          ? const Icon(Icons.event_rounded)
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.clear),
                              onPressed: () => setState(() => _followUp = null),
                            ),
                    ),
                    child: Text(_followUp == null ? 'None' : dateFmt.format(_followUp!)),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              TextField(
                controller: _notes,
                minLines: 2,
                maxLines: 5,
                decoration: InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: _type == DocType.prescription
                      ? 'Diagnosis, advice, follow-up date…'
                      : "Doctor's comments, medicines, symptoms…",
                  alignLabelWithHint: true,
                ),
              ),
              if (_type == DocType.prescription && _isNew && _medicines.isEmpty && _extractedBy == null) ...[
                const SizedBox(height: 12),
                Text('After saving you can add the medicines and set reminders.', style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Progress, failure or the outcome of AI reading. A failure keeps everything
  /// on the form, so the user can always carry on without AI.
  List<Widget> _aiPanel(ThemeData theme) {
    final colors = theme.colorScheme;
    if (_aiRunning) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(_aiStage)),
                    TextButton(onPressed: () => _aiCancel?.cancel(), child: const Text('Cancel')),
                  ],
                ),
                const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ];
    }
    final error = _aiError;
    if (error != null) {
      return [
        Card(
          color: colors.errorContainer,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(error.message, style: TextStyle(color: colors.onErrorContainer)),
                const SizedBox(height: 4),
                Text(
                  'Your file is safe. You can save it now and read it later.',
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
                ),
                if (error.detail != null)
                  Text(
                    error.detail!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: Wrap(
                    children: [
                      if (error.needsSettings)
                        TextButton(
                          onPressed: () =>
                              Navigator.push(context, MaterialPageRoute(builder: (_) => const AiSettingsScreen())),
                          child: const Text('AI settings'),
                        ),
                      TextButton(onPressed: _runAi, child: const Text('Try again')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }
    final draft = _aiDraft;
    if (draft == null) return const [];
    final total = draft.results.length + draft.medicines.length;
    final toCheck = _rows.where((r) => r.needsReview).length + _medicines.where((m) => m.check.needsReview).length;
    return [
      Card(
        color: colors.secondaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                total == 0
                    ? 'No values were found. The original is attached.'
                    : toCheck == 0
                    ? 'Read $total item${total == 1 ? '' : 's'}, all matched on-device. Check them against the original, then save.'
                    : 'Read $total item${total == 1 ? '' : 's'}. $toCheck need${toCheck == 1 ? 's' : ''} checking against the original.',
                style: TextStyle(color: colors.onSecondaryContainer, fontWeight: FontWeight.w600),
              ),
              if (!draft.hadLocalText && total > 0)
                Text(
                  "The device couldn't read this page by itself, so nothing could be cross-checked.",
                  style: TextStyle(color: colors.onSecondaryContainer),
                ),
              for (final issue in _aiIssues)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 18, color: colors.onSecondaryContainer),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(issue, style: TextStyle(color: colors.onSecondaryContainer)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _medicinesSection(ThemeData theme) => [
    const SizedBox(height: 20),
    Text('Medicines found', style: theme.textTheme.titleSmall),
    Text(
      'Saved with reminders. Tap one to change it.',
      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
    ),
    const SizedBox(height: 4),
    for (final m in _medicines)
      Card(
        color: m.check.needsReview || m.times == null ? StatusColors.warning.withValues(alpha: 0.12) : null,
        child: ListTile(
          title: Text([m.name, ?m.dose].join(' · ')),
          subtitle: Text(
            [
              m.times == null || m.times!.isEmpty
                  ? 'Set dose times'
                  : m.times!.map((t) => formatTime(context, t)).join(', '),
              if (m.ongoing) 'ongoing' else if (m.days != null) '${m.days} days' else 'set duration',
              ?m.scheduleText == null ? null : 'written "${m.scheduleText}"',
              ?m.note,
            ].join(' · '),
          ),
          onTap: () async {
            final changed = await showDialog<bool>(
              context: context,
              builder: (_) => _MedicineDialog(medicine: m),
            );
            if (changed == true) setState(() => m.check = Check.confirmed);
          },
          trailing: IconButton(
            tooltip: 'Remove',
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: () => setState(() => _medicines.remove(m)),
          ),
        ),
      ),
  ];

  List<Widget> _resultsSection(ThemeData theme) => [
    const SizedBox(height: 20),
    Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('Results', style: theme.textTheme.titleSmall),
        Wrap(
          children: [
            PopupMenuButton<String>(
              tooltip: 'Add a whole panel',
              onSelected: _addPanel,
              itemBuilder: (_) => [
                for (final p in panelOrder.where((p) => p != 'Custom')) PopupMenuItem(value: p, child: Text(p)),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [Icon(Icons.playlist_add_rounded, size: 20), SizedBox(width: 6), Text('Add panel')],
                ),
              ),
            ),
            TextButton.icon(onPressed: _addTest, icon: const Icon(Icons.add_rounded), label: const Text('Add test')),
          ],
        ),
      ],
    ),
    if (_rows.isEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'No results. Use "Add panel" or "Add test".',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    for (final row in _rows)
      _ResultRow(
        key: ObjectKey(row),
        row: row,
        onChanged: () => setState(() => row.touched = true),
        onEdit: () => _editRow(row),
        onUseAlternative: row.alternative == null
            ? null
            : () => setState(() {
                row.value.text = formatNumber(row.alternative!);
                row.touched = true;
              }),
        onRemove: () => setState(() {
          _rows.remove(row);
          row.value.dispose();
        }),
      ),
    if (_rows.any((r) => r.value.text.trim().isEmpty)) ...[
      const SizedBox(height: 8),
      Text(
        'Rows left empty are not saved.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    ],
  ];
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    super.key,
    required this.row,
    required this.onChanged,
    required this.onEdit,
    required this.onRemove,
    this.onUseAlternative,
  });
  final _Row row;
  final VoidCallback? onUseAlternative;
  final VoidCallback onChanged;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final range = formatRange(row.refLow, row.refHigh);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
      decoration: BoxDecoration(
        color: row.needsReview || row.check == Check.unreadable && !row.touched
            ? StatusColors.warning.withValues(alpha: 0.14)
            : abnormalTint(context, row.flag),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          if (row.check != null && !row.touched)
            Tooltip(
              message: switch (row.check!) {
                Check.confirmed => 'Matches what the device read on this row',
                Check.onPage => 'This number is on the page, but not tied to this row',
                Check.uncheckable => 'Could not be cross-checked',
                _ => 'Needs checking',
              },
              child: Padding(
                padding: const EdgeInsets.only(left: 2, right: 2),
                child: Icon(
                  row.check!.needsReview ? Icons.help_outline_rounded : Icons.verified_outlined,
                  size: 18,
                  color: row.check!.needsReview ? StatusColors.warning : theme.colorScheme.primary,
                ),
              ),
            ),
          Expanded(
            child: InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.testName, style: theme.textTheme.bodyLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(range.isEmpty ? 'Set reference range' : 'Range $range', style: muted),
                    if (row.note != null && !row.touched)
                      Text(row.note!, style: muted?.copyWith(color: theme.colorScheme.onSurface)),
                    if (onUseAlternative != null && !row.touched)
                      TextButton(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        onPressed: onUseAlternative,
                        child: Text('Use ${formatNumber(row.alternative!)}'),
                      ),
                    if (row.sourceLine != null)
                      Text(
                        '“${row.sourceLine}”',
                        style: muted?.copyWith(fontStyle: FontStyle.italic),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: TextField(
              controller: row.value,
              textAlign: TextAlign.end,
              style: isAbnormal(row.flag) ? valueStyle(context, row.flag, base: theme.textTheme.bodyLarge) : null,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(isDense: true, hintText: 'value'),
              onChanged: (_) => onChanged(),
            ),
          ),
          SizedBox(
            width: 72,
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(row.unit ?? '', style: muted, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ),
          SizedBox(width: 24, child: FlagBadge(row.flag, compact: true)),
          IconButton(tooltip: 'Remove', icon: const Icon(Icons.close_rounded, size: 20), onPressed: onRemove),
        ],
      ),
    );
  }
}

/// Corrects a medicine found on a prescription before it is saved.
class _MedicineDialog extends StatefulWidget {
  const _MedicineDialog({required this.medicine});
  final DraftMedicine medicine;

  @override
  State<_MedicineDialog> createState() => _MedicineDialogState();
}

class _MedicineDialogState extends State<_MedicineDialog> {
  static const _presets = {
    'Once a day': [8 * 60],
    'Twice a day': [8 * 60, 20 * 60],
    '3 times a day': [8 * 60, 14 * 60, 20 * 60],
    '4 times a day': [8 * 60, 12 * 60, 16 * 60, 20 * 60],
  };

  late final _name = TextEditingController(text: widget.medicine.name);
  late final _dose = TextEditingController(text: widget.medicine.dose);
  late final _days = TextEditingController(text: widget.medicine.days?.toString());
  late List<int>? _times = widget.medicine.times;
  late bool _ongoing = widget.medicine.ongoing;

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Medicine'),
    content: SizedBox(
      width: 360,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _dose,
            decoration: const InputDecoration(labelText: 'Strength / dose'),
          ),
          if (widget.medicine.scheduleText != null) ...[
            const SizedBox(height: 12),
            Text('Written as: ${widget.medicine.scheduleText}', style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final e in _presets.entries)
                ChoiceChip(
                  label: Text(e.key),
                  selected: _times != null && _times!.length == e.value.length && _times!.toSet().containsAll(e.value),
                  onSelected: (_) => setState(() => _times = e.value),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _days,
            enabled: !_ongoing,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'For how many days'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ongoing'),
            value: _ongoing,
            onChanged: (v) => setState(() => _ongoing = v),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
      FilledButton(
        onPressed: () {
          final days = int.tryParse(_days.text.trim());
          widget.medicine
            ..name = _name.text.trim().isEmpty ? widget.medicine.name : _name.text.trim()
            ..dose = _dose.text.trim().isEmpty ? null : _dose.text.trim()
            ..times = _times
            ..ongoing = _ongoing
            ..days = days != null && days >= 1 && days <= 3650 ? days : null
            ..note = null;
          Navigator.pop(context, true);
        },
        child: const Text('Done'),
      ),
    ],
  );
}

/// Edit name, unit and reference range of a row.
class _RowDialog extends StatefulWidget {
  const _RowDialog({required this.row});
  final _Row row;

  @override
  State<_RowDialog> createState() => _RowDialogState();
}

class _RowDialogState extends State<_RowDialog> {
  late final _name = TextEditingController(text: widget.row.testName);
  late final _unit = TextEditingController(text: widget.row.unit);
  late final _low = TextEditingController(text: widget.row.refLow == null ? '' : formatNumber(widget.row.refLow!));
  late final _high = TextEditingController(text: widget.row.refHigh == null ? '' : formatNumber(widget.row.refHigh!));

  @override
  Widget build(BuildContext context) {
    const numKb = TextInputType.numberWithOptions(decimal: true);
    return AlertDialog(
      scrollable: true,
      title: const Text('Test details'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Test name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _unit,
              decoration: const InputDecoration(labelText: 'Unit'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _low,
                    keyboardType: numKb,
                    decoration: const InputDecoration(labelText: 'Range low'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _high,
                    keyboardType: numKb,
                    decoration: const InputDecoration(labelText: 'Range high'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Use the range printed on the report.', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final row = widget.row;
            final name = _name.text.trim();
            if (name.isNotEmpty && name != row.testName) {
              final known = findTest(name);
              row
                ..testName = known?.name ?? name
                ..testKey = known?.key ?? customKey(name);
            }
            row
              ..unit = _unit.text.trim().isEmpty ? null : _unit.text.trim()
              ..refLow = double.tryParse(_low.text.trim())
              ..refHigh = double.tryParse(_high.text.trim());
            Navigator.pop(context, true);
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Search the catalog; returns a [LabTest] or a custom name [String].
class _TestPicker extends StatefulWidget {
  const _TestPicker();

  @override
  State<_TestPicker> createState() => _TestPickerState();
}

class _TestPickerState extends State<_TestPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final matches = labCatalog
        .where((t) => q.isEmpty || t.name.toLowerCase().contains(q) || t.aliases.any((a) => a.contains(q)))
        .toList();
    return AlertDialog(
      title: const Text('Add test'),
      contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
      content: SizedBox(
        width: 400,
        height: 460,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search, e.g. ferritin, TSH',
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (q.isNotEmpty)
                    ListTile(
                      leading: const Icon(Icons.add_rounded),
                      title: Text('Add "${_q.trim()}" as a new test'),
                      onTap: () => Navigator.pop(context, _q.trim()),
                    ),
                  for (final t in matches)
                    ListTile(
                      title: Text(t.name),
                      subtitle: Text('${t.panel} · ${t.unit}'),
                      onTap: () => Navigator.pop(context, t),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}
