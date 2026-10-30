import 'dart:convert';

import '../../data/lab_catalog.dart';
import '../../data/models.dart';
import '../medicine_schedule.dart';
import '../report_parser.dart';
import '../text_tools.dart';
import 'ai_client.dart';
import 'extraction_prompt.dart';

// ---------------------------------------------------------------- Model reply

String? _clean(Object? v) {
  if (v is! String) return null;
  final s = v.trim();
  return const {'', '-', '--', 'n/a', 'na', 'null', 'none', 'unknown'}.contains(s.toLowerCase()) ? null : s;
}

/// A printed row, exactly as the model transcribed it.
class AiLabRow {
  AiLabRow(this.name, this.value, this.unit, this.range, this.flag, this.legible, this.source);
  final String name;
  final String? value;
  final String? unit;
  final String? range;
  final String? flag;
  final bool legible;
  final String? source;
}

class AiMedicine {
  AiMedicine(this.name, this.strength, this.schedule, this.duration, this.instructions, this.legible, this.source);
  final String name;
  final String? strength;
  final String? schedule;
  final String? duration;
  final String? instructions;
  final bool legible;
  final String? source;
}

/// The model's reply, checked for shape. Anything malformed throws, so a
/// half-understood answer is never partly used.
class AiDocument {
  AiDocument({
    required this.isMedical,
    required this.type,
    this.title,
    this.datePrinted,
    this.dateIso,
    this.patientName,
    this.patientAge,
    this.patientSex,
    this.otherPatients = const [],
    this.facility,
    this.doctorName,
    this.doctorSpecialty,
    this.doctorHospital,
    this.doctorPhone,
    this.labRows = const [],
    this.medicines = const [],
    this.notes,
    this.followUpText,
    this.followUpDate,
    this.followUpDays,
  });

  final bool isMedical;
  final DocType type;
  final String? title;
  final String? datePrinted;
  final String? dateIso;
  final String? patientName;
  final String? patientAge;
  final String? patientSex;
  final List<String> otherPatients;
  final String? facility;
  final String? doctorName;
  final String? doctorSpecialty;
  final String? doctorHospital;
  final String? doctorPhone;
  final List<AiLabRow> labRows;
  final List<AiMedicine> medicines;
  final String? notes;
  final String? followUpText;
  final String? followUpDate;
  final int? followUpDays;

  /// Parses model output, tolerating code fences and stray text around the object.
  static AiDocument parse(String text) {
    final start = text.indexOf('{'), end = text.lastIndexOf('}');
    if (start < 0 || end <= start) throw const FormatException('No JSON object');
    final m = jsonDecode(text.substring(start, end + 1));
    if (m is! Map<String, Object?>) throw const FormatException('Not an object');
    if (m['is_medical_document'] is! bool) throw const FormatException('is_medical_document missing');
    if (m['lab_results'] is! List || m['medicines'] is! List) throw const FormatException('Lists missing');
    final patient = m['patient'] as Map<String, Object?>? ?? const {};
    final doctor = m['doctor'] as Map<String, Object?>? ?? const {};
    return AiDocument(
      isMedical: m['is_medical_document'] as bool,
      type: DocType.fromId(m['document_type'] as String?),
      title: _clean(m['title']),
      datePrinted: _clean(m['report_date_printed']),
      dateIso: _clean(m['report_date']),
      patientName: _clean(patient['name_printed']),
      patientAge: _clean(patient['age_printed']),
      patientSex: _clean(patient['sex_printed']),
      otherPatients: [
        for (final p in m['other_patients'] as List? ?? const [])
          if (_clean(p) != null) _clean(p)!,
      ],
      facility: _clean(m['facility']),
      doctorName: _clean(doctor['name_printed']),
      doctorSpecialty: _clean(doctor['specialty_printed']),
      doctorHospital: _clean(doctor['hospital_printed']),
      doctorPhone: _clean(doctor['phone_printed']),
      labRows: [
        for (final r in (m['lab_results'] as List).cast<Map<String, Object?>>())
          if (_clean(r['test_name_printed']) != null)
            AiLabRow(
              _clean(r['test_name_printed'])!,
              _clean(r['value_printed']),
              _clean(r['unit_printed']),
              _clean(r['reference_range_printed']),
              _clean(r['flag_printed']),
              r['legible'] != false,
              _clean(r['source_text']),
            ),
      ],
      medicines: [
        for (final r in (m['medicines'] as List).cast<Map<String, Object?>>())
          if (_clean(r['name_printed']) != null)
            AiMedicine(
              _clean(r['name_printed'])!,
              _clean(r['strength_printed']),
              _clean(r['schedule_printed']),
              _clean(r['duration_printed']),
              _clean(r['instructions_printed']),
              r['legible'] != false,
              _clean(r['source_text']),
            ),
      ],
      notes: _clean(m['notes_printed']),
      followUpText: _clean(m['follow_up_printed']),
      followUpDate: _clean(m['follow_up_date']),
      followUpDays: m['follow_up_days'] is int ? m['follow_up_days'] as int : null,
    );
  }
}

// ---------------------------------------------------------------- Checked draft

/// How well a value is backed up by a reading that didn't come from the AI.
enum Check {
  /// Found on the same line as the test name.
  confirmed,

  /// The number is on the page, but not tied to this row.
  onPage,

  /// There was no on-device text to compare with (often handwriting).
  uncheckable,

  /// The on-device reading doesn't contain this value.
  notFound,

  /// The on-device reading found a different value for this test.
  conflict,

  /// The AI could not read it.
  unreadable,

  /// Found only by the on-device reader; the AI skipped it.
  localOnly;

  /// The user should compare this one with the original.
  bool get needsReview => this != confirmed && this != onPage;
}

class DraftResult {
  DraftResult(this.parsed, this.check, {this.note, this.alternative});
  final ParsedResult parsed;
  final Check check;

  /// Why it needs a look, in plain words.
  String? note;

  /// The on-device reader's different value, offered as a one-tap replacement.
  final double? alternative;
}

class DraftMedicine {
  DraftMedicine({
    required this.name,
    this.dose,
    this.times,
    this.days,
    this.ongoing = false,
    this.instructions,
    this.scheduleText,
    this.durationText,
    required this.check,
    this.note,
  });
  String name;
  String? dose;

  /// Null means the schedule couldn't be worked out, so the user must set it.
  List<int>? times;
  int? days;
  bool ongoing;
  String? instructions;
  final String? scheduleText;
  final String? durationText;
  Check check;
  String? note;
}

class DraftDoctor {
  DraftDoctor({required this.name, this.specialty, this.hospital, this.phone, this.matchId});
  final String name;
  final String? specialty;
  final String? hospital;
  final String? phone;

  /// An existing doctor this is the same person as.
  final String? matchId;
}

/// Everything read from a document, checked and ready for the review screen.
class ExtractionDraft {
  ExtractionDraft({
    required this.type,
    this.title,
    this.date,
    this.lab,
    this.doctor,
    this.results = const [],
    this.medicines = const [],
    this.notes,
    this.followUp,
    this.issues = const [],
    this.hadLocalText = false,
  });

  final DocType type;
  final String? title;
  final DateTime? date;
  final String? lab;
  final DraftDoctor? doctor;
  final List<DraftResult> results;
  final List<DraftMedicine> medicines;
  final String? notes;
  final DateTime? followUp;

  /// Problems with the document as a whole, shown at the top of the review.
  final List<String> issues;
  final bool hadLocalText;

  int get toReview =>
      results.where((r) => r.check.needsReview).length + medicines.where((m) => m.check.needsReview).length;
}

// ---------------------------------------------------------------- Patient and doctor matching

const _honorifics = {
  'mr',
  'mrs',
  'ms',
  'miss',
  'md',
  'mst',
  'mosammat',
  'mohammad',
  'mohammed',
  'muhammad',
  'sk',
  'master',
  'baby',
  'late',
  'dr',
  'prof',
  'professor',
  'assoc',
  'asst',
  'brig',
  'gen',
  'col',
  'maj',
};

/// Name words, without titles or anything after a comma (degrees).
List<String> nameWords(String name) => name
    .split(',')
    .first
    .replaceAll(RegExp(r'\([^)]*\)'), ' ')
    .toLowerCase()
    .split(RegExp(r'[^\p{L}\p{M}]+', unicode: true))
    .where((w) => w.length > 1 && !_honorifics.contains(w))
    .toList();

/// True when every word of the shorter name appears in the longer one.
bool namesMatch(String a, String b) {
  var x = nameWords(a), y = nameWords(b);
  if (x.isEmpty || y.isEmpty) return false;
  if (x.length > y.length) (x, y) = (y, x);
  return x.every((w) => y.any((v) => sameWord(w, v)));
}

enum PatientStatus { matchesCurrent, matchesOther, noMatch, notPrinted }

class PatientMatch {
  PatientMatch(this.status, {this.printedName, this.member});
  final PatientStatus status;
  final String? printedName;

  /// The family member named on the document.
  final Member? member;
}

/// Decides whose document this is from the printed name. The model never sees
/// the family, so this comparison happens only here.
PatientMatch matchPatient(AiDocument doc, List<Member> family, Member? current) {
  final name = doc.patientName;
  if (name == null) return PatientMatch(PatientStatus.notPrinted);
  if (current != null && namesMatch(name, current.name)) {
    return PatientMatch(PatientStatus.matchesCurrent, printedName: name, member: current);
  }
  final hits = family.where((m) => namesMatch(name, m.name)).toList();
  // Two members fitting equally ("Rahman") is no answer at all.
  if (hits.length == 1) return PatientMatch(PatientStatus.matchesOther, printedName: name, member: hits.single);
  return PatientMatch(PatientStatus.noMatch, printedName: name);
}

String? matchDoctor(String name, List<Doctor> doctors) {
  final hits = doctors
      .where((d) => nameWords(d.name).length >= 2 && nameWords(name).length >= 2 && namesMatch(name, d.name))
      .toList();
  return hits.length == 1 ? hits.single.id : null;
}

// ---------------------------------------------------------------- Checks

/// Compares what the AI read with what the device read independently. Only
/// this code decides numbers: printed strings go through the same parser as
/// on-device reading, so the model can't convert or "correct" a value.
class ExtractionChecker {
  ExtractionChecker({required this.member, this.doctors = const [], this.history = const {}, DateTime? today})
    : today = today ?? DateTime.now();

  final Member? member;
  final List<Doctor> doctors;

  /// Last value per test key for this member.
  final Map<String, double> history;
  final DateTime today;

  /// A new value this many times away from the last one is probably a slipped decimal.
  static const _jumpFactor = 5;

  ExtractionDraft check(AiDocument doc, List<String> localLines) {
    final lines = localLines.map((l) => asciiDigits(l).toLowerCase()).where((l) => l.trim().isNotEmpty).toList();
    final parser = ReportParser(sex: member?.sex);
    final local = parser.parse(localLines);
    final hasText = lines.length > 3;
    final numbers = hasText ? lines.expand(numbersIn).toSet() : const <double>{};
    final issues = <String>[];

    if (!doc.isMedical) issues.add("This doesn't look like a medical document. Nothing was read from it.");
    if (doc.otherPatients.isNotEmpty) {
      issues.add(
        'These pages also mention ${doc.otherPatients.join(', ')}. Only one person\'s details were read: split the file if it holds several people\'s reports.',
      );
    }
    final sexIssue = _sexIssue(doc);
    if (sexIssue != null) issues.add(sexIssue);
    final ageIssue = _ageIssue(doc, local.date);
    if (ageIssue != null) issues.add(ageIssue);

    final (date, dateIssue) = _resolveDate(doc, local.date);
    if (dateIssue != null) issues.add(dateIssue);

    final results = <DraftResult>[];
    final seen = <String, double?>{};
    final localByKey = {for (final r in local.results) r.testKey: r};
    final keep = doc.isMedical ? doc.labRows : const <AiLabRow>[];

    for (final row in keep) {
      final draft = _checkRow(row, parser, localByKey, lines, numbers, hasText);
      if (draft == null) continue;
      final key = draft.parsed.testKey;
      if (seen.containsKey(key)) {
        if (seen[key] == draft.parsed.value) continue;
        // Same catalog test twice with different values, e.g. a percentage and
        // an absolute count. Kept apart so they never share a trend line.
        draft.parsed
          ..testKey = customKey(row.name)
          ..testName = row.name;
        if (seen.containsKey(draft.parsed.testKey)) continue;
      }
      seen[draft.parsed.testKey] = draft.parsed.value;
      results.add(draft);
    }

    // Nothing the on-device reader found is lost just because the AI skipped it.
    if (doc.isMedical && doc.type == DocType.lab) {
      for (final r in local.results.where((r) => !seen.containsKey(r.testKey))) {
        results.add(
          DraftResult(r, Check.localOnly, note: "Only the on-device reader found this. Check it's a real result."),
        );
      }
    }

    final medicines = [
      if (doc.isMedical)
        for (final m in doc.medicines) _checkMedicine(m, lines, hasText),
    ];

    final aiRead = results.where((r) => r.check != Check.localOnly).toList();
    if (hasText && aiRead.isNotEmpty && aiRead.where((r) => r.check == Check.notFound).length > aiRead.length / 2) {
      issues.add(
        "Most values couldn't be found by the on-device reader. If this is handwritten or a poor photo, check each one against the original.",
      );
    }

    final name = doc.doctorName;
    return ExtractionDraft(
      type: doc.type,
      title: doc.title,
      date: date,
      lab: doc.facility,
      doctor: name == null
          ? null
          : DraftDoctor(
              name: name,
              specialty: doc.doctorSpecialty,
              hospital: doc.doctorHospital ?? doc.facility,
              phone: doc.doctorPhone,
              matchId: matchDoctor(name, doctors),
            ),
      results: results,
      medicines: medicines,
      notes: doc.notes,
      followUp: _followUp(doc, date),
      issues: issues,
      hadLocalText: hasText,
    );
  }

  DraftResult? _checkRow(
    AiLabRow row,
    ReportParser parser,
    Map<String, ParsedResult> localByKey,
    List<String> lines,
    Set<double> numbers,
    bool hasText,
  ) {
    if (row.value == null || !row.legible) {
      final test = ReportParser.matchTest(row.name);
      final own = localByKey[test?.key];
      if (own != null) {
        return DraftResult(
          own,
          Check.localOnly,
          note: 'The AI could not read this; this value is from the on-device reader.',
        );
      }
      return DraftResult(
        ParsedResult(
          testKey: test?.key ?? customKey(row.name),
          testName: test?.name ?? row.name,
          unit: test?.unit ?? row.unit,
          valueText: null,
          sourceLine: row.source ?? row.name,
        ),
        Check.unreadable,
        note: "Couldn't be read. Type it in from the original, or remove it.",
      );
    }
    final p = parser.fromFields(
      name: row.name,
      valuePrinted: row.value!,
      unit: row.unit,
      range: row.range,
      sourceLine: row.source ?? '${row.name} ${row.value}',
    );
    if (p == null) return null;

    final notes = <String>[];
    if (p.refLow != null && p.refHigh != null && p.refLow! > p.refHigh!) {
      p
        ..refLow = null
        ..refHigh = null;
      notes.add('The printed range made no sense, so it was dropped.');
    }

    final printedNumber = p.value == null ? null : numbersIn(row.value!).firstOrNull;
    var check = Check.confirmed;
    double? alternative;
    final other = localByKey[p.testKey];
    if (p.value != null && other?.value != null && !_close(other!.value!, p.value!)) {
      check = Check.conflict;
      alternative = other.value;
      notes.add('The on-device reader saw ${_fmt(other.value!)} here.');
    } else if (printedNumber == null) {
      check = hasText && lines.any((l) => l.contains(row.value!.toLowerCase()))
          ? Check.confirmed
          : (hasText ? Check.notFound : Check.uncheckable);
    } else if (!hasText) {
      check = Check.uncheckable;
    } else if (!numbers.any((n) => _close(n, printedNumber))) {
      check = Check.notFound;
      notes.add('This number was not found by the on-device reader.');
    } else if (!_onRow(row.name, printedNumber, lines)) {
      check = Check.onPage;
    }

    final last = history[p.testKey];
    if (p.value != null && last != null && last > 0 && p.value! > 0) {
      final ratio = p.value! > last ? p.value! / last : last / p.value!;
      if (ratio >= _jumpFactor) {
        notes.add('Very different from the last result (${_fmt(last)}). Check the decimal point.');
        if (!check.needsReview) check = Check.notFound;
      }
    }

    final flagIssue = _flagIssue(row.flag, p);
    if (flagIssue != null) {
      notes.add(flagIssue);
      if (!check.needsReview) check = Check.notFound;
    }
    return DraftResult(p, check, note: notes.isEmpty ? null : notes.join(' '), alternative: alternative);
  }

  static bool _close(double a, double b) => (a - b).abs() <= 0.005 * (a.abs() > b.abs() ? a.abs() : b.abs());

  static String _fmt(double v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';

  /// The value sits on a line naming this test, or on the line after a bare name.
  static bool _onRow(String name, double number, List<String> lines) {
    final words = [
      for (final w in name.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
        if (w.length >= 3) w,
      ...?ReportParser.matchTest(name)?.aliases,
    ];
    if (words.isEmpty) return false;
    for (var i = 0; i < lines.length; i++) {
      if (!words.any(lines[i].contains)) continue;
      final here = numbersIn(lines[i]);
      if (here.any((n) => _close(n, number))) return true;
      if (here.isEmpty && i + 1 < lines.length && numbersIn(lines[i + 1]).any((n) => _close(n, number))) return true;
    }
    return false;
  }

  /// A printed H/L that disagrees with value vs range means one of them was misread.
  static String? _flagIssue(String? printed, ParsedResult p) {
    if (printed == null || p.value == null || (p.refLow == null && p.refHigh == null)) return null;
    final f = printed.trim().toLowerCase();
    final high = RegExp(r'^(h|hi|high|↑|\*h)$').hasMatch(f);
    final low = RegExp(r'^(l|lo|low|↓|\*l)$').hasMatch(f);
    final isHigh = p.refHigh != null && p.value! > p.refHigh!;
    final isLow = p.refLow != null && p.value! < p.refLow!;
    if ((high && !isHigh) || (low && !isLow)) {
      return 'The report marks this ${high ? 'high' : 'low'}, but the value and range read here say otherwise.';
    }
    return null;
  }

  DraftMedicine _checkMedicine(AiMedicine m, List<String> lines, bool hasText) {
    final times = MedicineSchedule.parseTimes(m.schedule);
    final duration = MedicineSchedule.parseDuration(m.duration);
    final notes = <String>[];
    var check = Check.confirmed;
    if (!m.legible) {
      check = Check.unreadable;
      notes.add('The name was hard to read. Check it against the prescription.');
    } else if (!hasText) {
      check = Check.uncheckable;
    } else {
      final word = m.name
          .toLowerCase()
          .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
          .firstWhere((w) => w.length >= 3, orElse: () => '');
      final found =
          word.isNotEmpty &&
          lines.any((l) => l.split(RegExp(r'[^\p{L}\p{N}]+', unicode: true)).any((w) => sameWord(w, word)));
      if (!found) {
        check = Check.notFound;
        notes.add('The on-device reader could not find this name. Check it against the prescription.');
      }
    }
    if (times == null) notes.add('Set the dose times.');
    if (duration.days == null && !duration.ongoing) notes.add('Set how long to take it.');
    return DraftMedicine(
      name: m.name,
      dose: m.strength,
      times: times,
      days: duration.days,
      ongoing: duration.ongoing,
      instructions: m.instructions,
      scheduleText: m.schedule,
      durationText: m.duration,
      check: check,
      note: notes.isEmpty ? null : notes.join(' '),
    );
  }

  (DateTime?, String?) _resolveDate(AiDocument doc, DateTime? localDate) {
    DateTime? date;
    final printed = doc.datePrinted == null
        ? const <DateTime>[]
        : parseDates(asciiDigits(doc.datePrinted!).toLowerCase());
    if (printed.isNotEmpty) {
      // Our day-first rule decides, not the model's reading of an ambiguous date.
      date = printed.first;
    } else if (doc.dateIso != null) {
      date = DateTime.tryParse(doc.dateIso!);
    }
    if (date != null && (date.isAfter(today) || date.year < 1950)) {
      return (
        localDate,
        'The date read from the document (${doc.datePrinted ?? doc.dateIso}) is not possible. Please check it.',
      );
    }
    if (date == null) return (localDate, null);
    if (localDate != null && dateToDb(localDate) != dateToDb(date)) {
      return (date, 'Check the date: the AI read ${dateToDb(date)}, the on-device reader ${dateToDb(localDate)}.');
    }
    return (date, null);
  }

  DateTime? _followUp(AiDocument doc, DateTime? date) {
    final exact = doc.followUpDate == null ? null : DateTime.tryParse(doc.followUpDate!);
    final from = date ?? today;
    final result =
        exact ??
        (doc.followUpDays != null && doc.followUpDays! > 0 && doc.followUpDays! <= 730
            ? DateTime(from.year, from.month, from.day + doc.followUpDays!)
            : null);
    return result != null && result.isAfter(from) ? result : null;
  }

  String? _sexIssue(AiDocument doc) {
    final s = doc.patientSex?.toLowerCase().trim();
    final sex = member?.sex;
    if (s == null || sex == null) return null;
    final printed = RegExp(r'^(f|female|woman|mrs|মহিলা|নারী)').hasMatch(s)
        ? 'F'
        : (RegExp(r'^(m|male|man|পুরুষ)').hasMatch(s) ? 'M' : null);
    if (printed == null || printed == sex) return null;
    return 'The document says ${doc.patientSex}, which differs from ${member!.name}\'s profile. Is this the right person?';
  }

  String? _ageIssue(AiDocument doc, DateTime? localDate) {
    final birth = member?.birthDate;
    final printed = doc.patientAge == null ? null : numbersIn(doc.patientAge!).firstOrNull;
    if (birth == null || printed == null) return null;
    // Printed ages for babies are often in months or days.
    if (RegExp(r'mon|month|day|week|মাস|দিন').hasMatch(doc.patientAge!.toLowerCase())) return null;
    final at = localDate ?? today;
    final age = (at.difference(birth).inDays / 365.25).floor();
    if ((age - printed).abs() <= 2) return null;
    return 'The document gives age ${printed.toInt()}, but ${member!.name} would be $age. Is this the right person?';
  }
}

// ---------------------------------------------------------------- Running it

/// Reads a prepared document. Asks a second time if the reply is unusable,
/// since a malformed answer is usually a one-off.
class AiReader {
  AiReader(this.backend);
  final AiBackend backend;

  Future<AiDocument> read({
    required List<AiImage> images,
    required List<String> localLines,
    AiCancelToken? cancel,
  }) async {
    final text = localLines.where((l) => l.trim().isNotEmpty).join('\n');
    if (images.isEmpty && text.isEmpty) {
      throw const AiException(AiErrorKind.unsupported, detail: 'No images or text to send.');
    }
    final request = AiRequest(
      system: extractionSystemPrompt,
      prompt: images.isEmpty
          ? '$extractionUserPrompt\n\nThe document, as text read by a scanner:\n<document>\n$text\n</document>'
          : extractionUserPrompt,
      images: images,
      schema: extractionSchema,
    );
    for (var attempt = 1; ; attempt++) {
      final reply = await backend.complete(request, cancel: cancel);
      try {
        return AiDocument.parse(reply);
      } on Object catch (e) {
        if (attempt >= 2) throw AiException(AiErrorKind.invalidResponse, detail: '$e');
      }
    }
  }
}
