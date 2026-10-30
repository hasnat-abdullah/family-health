import 'package:uuid/uuid.dart';

const _uuid = Uuid();
String newId() => _uuid.v4();

int _now() => DateTime.now().millisecondsSinceEpoch;

/// Dates without a time component are stored as `yyyy-MM-dd` so they sort as text.
String dateToDb(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime dateFromDb(String s) => DateTime.parse(s);

// Every record carries a UUID and `updatedAt` so archives from different devices
// can be merged (last write wins), and so a future cloud sync has what it needs.

class Member {
  Member({
    String? id,
    required this.name,
    this.relation,
    this.birthDate,
    this.sex,
    this.bloodGroup,
    required this.colorValue,
    this.notes,
    this.photoFile,
    int? updatedAt,
  }) : id = id ?? newId(),
       updatedAt = updatedAt ?? _now();

  final String id;
  String name;
  String? relation;
  DateTime? birthDate;

  /// 'F', 'M' or null. Used to pick default reference ranges.
  String? sex;
  String? bloodGroup;
  int colorValue;
  String? notes;

  /// Profile picture: a file name in the encrypted [FileStore], or null for initials.
  String? photoFile;
  int updatedAt;

  int? get age {
    final b = birthDate;
    if (b == null) return null;
    final now = DateTime.now();
    var years = now.year - b.year;
    if (now.month < b.month || (now.month == b.month && now.day < b.day)) years--;
    return years;
  }

  String get initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'relation': relation,
    'birth_date': birthDate == null ? null : dateToDb(birthDate!),
    'sex': sex,
    'blood_group': bloodGroup,
    'color': colorValue,
    'notes': notes,
    'photo_file': photoFile,
    'updated_at': updatedAt,
  };

  factory Member.fromMap(Map<String, Object?> m) => Member(
    id: m['id'] as String,
    name: m['name'] as String,
    relation: m['relation'] as String?,
    birthDate: m['birth_date'] == null ? null : dateFromDb(m['birth_date'] as String),
    sex: m['sex'] as String?,
    bloodGroup: m['blood_group'] as String?,
    colorValue: m['color'] as int,
    notes: m['notes'] as String?,
    photoFile: m['photo_file'] as String?,
    updatedAt: m['updated_at'] as int,
  );
}

/// A doctor the family consults. Shared across members, so one doctor's page
/// can show everyone they treat.
class Doctor {
  Doctor({String? id, required this.name, this.specialty, this.hospital, this.phone, this.notes, int? updatedAt})
    : id = id ?? newId(),
      updatedAt = updatedAt ?? _now();

  final String id;
  String name;
  String? specialty;
  String? hospital;
  String? phone;
  String? notes;
  int updatedAt;

  String get initials {
    final parts = name.replaceFirst(RegExp(r'^(prof|dr)\.?\s+', caseSensitive: false), '').trim().split(RegExp(r'\s+'));
    if (parts.first.isEmpty) return '?';
    return (parts.length == 1 ? parts.first[0] : parts.first[0] + parts.last[0]).toUpperCase();
  }

  /// Specialty and hospital on one line.
  String get details => [?specialty, ?hospital].join(' · ');

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'specialty': specialty,
    'hospital': hospital,
    'phone': phone,
    'notes': notes,
    'updated_at': updatedAt,
  };

  factory Doctor.fromMap(Map<String, Object?> m) => Doctor(
    id: m['id'] as String,
    name: m['name'] as String,
    specialty: m['specialty'] as String?,
    hospital: m['hospital'] as String?,
    phone: m['phone'] as String?,
    notes: m['notes'] as String?,
    updatedAt: m['updated_at'] as int,
  );
}

/// What kind of record a [Report] is. Lab reports carry results; the rest
/// are kept as documents (originals + notes).
enum DocType {
  lab('lab', 'Lab report'),
  prescription('prescription', 'Prescription'),
  imaging('imaging', 'X-ray / Scan'),
  discharge('discharge', 'Discharge summary'),
  vaccination('vaccination', 'Vaccination'),
  other('other', 'Other document');

  const DocType(this.id, this.label);
  final String id;
  final String label;

  static DocType fromId(String? id) => values.firstWhere((t) => t.id == id, orElse: () => DocType.other);
}

class Report {
  Report({
    String? id,
    required this.memberId,
    required this.title,
    required this.date,
    this.type = DocType.lab,
    this.lab,
    this.notes,
    this.doctorId,
    this.followUp,
    this.extractedBy,
    int? updatedAt,
  }) : id = id ?? newId(),
       updatedAt = updatedAt ?? _now();

  final String id;
  final String memberId;
  String title;
  DateTime date;
  DocType type;
  String? lab;
  String? notes;

  /// Consulting or referring doctor, if known.
  String? doctorId;

  /// Next visit or repeat-test date.
  DateTime? followUp;

  /// Which AI read this record (for example `Gemini · gemini-3.8-flash`), or null.
  String? extractedBy;
  int updatedAt;

  Map<String, Object?> toMap() => {
    'id': id,
    'member_id': memberId,
    'title': title,
    'date': dateToDb(date),
    'type': type.id,
    'lab': lab,
    'notes': notes,
    'doctor_id': doctorId,
    'follow_up': followUp == null ? null : dateToDb(followUp!),
    'extracted_by': extractedBy,
    'updated_at': updatedAt,
  };

  factory Report.fromMap(Map<String, Object?> m) => Report(
    id: m['id'] as String,
    memberId: m['member_id'] as String,
    title: m['title'] as String,
    date: dateFromDb(m['date'] as String),
    type: DocType.fromId(m['type'] as String?),
    lab: m['lab'] as String?,
    notes: m['notes'] as String?,
    doctorId: m['doctor_id'] as String?,
    followUp: m['follow_up'] == null ? null : dateFromDb(m['follow_up'] as String),
    extractedBy: m['extracted_by'] as String?,
    updatedAt: m['updated_at'] as int,
  );
}

/// An original report file (photo or PDF) kept exactly as received.
class Attachment {
  Attachment({
    String? id,
    required this.reportId,
    required this.fileName,
    required this.originalName,
    required this.mime,
    this.sha256,
    int? updatedAt,
  }) : id = id ?? newId(),
       updatedAt = updatedAt ?? _now();

  final String id;
  final String reportId;

  /// Name inside the app's attachment folder (unique).
  final String fileName;
  final String originalName;
  final String mime;

  /// Hash of the original bytes, used to spot a file imported twice.
  final String? sha256;
  int updatedAt;

  bool get isPdf => mime == 'application/pdf';

  Map<String, Object?> toMap() => {
    'id': id,
    'report_id': reportId,
    'file_name': fileName,
    'original_name': originalName,
    'mime': mime,
    'sha256': sha256,
    'updated_at': updatedAt,
  };

  factory Attachment.fromMap(Map<String, Object?> m) => Attachment(
    id: m['id'] as String,
    reportId: m['report_id'] as String,
    fileName: m['file_name'] as String,
    originalName: m['original_name'] as String,
    mime: m['mime'] as String,
    sha256: m['sha256'] as String?,
    updatedAt: m['updated_at'] as int,
  );
}

enum ResultFlag { low, normal, high, unknown }

class TestResult {
  TestResult({
    String? id,
    required this.reportId,
    required this.memberId,
    required this.testKey,
    required this.testName,
    this.value,
    this.valueText,
    this.unit,
    this.refLow,
    this.refHigh,
    required this.date,
    int? updatedAt,
  }) : id = id ?? newId(),
       updatedAt = updatedAt ?? _now();

  final String id;
  String reportId;
  String memberId;

  /// Catalog key (e.g. `hemoglobin`) or `custom:<slug>` for tests not in the catalog.
  /// Results sharing a key are plotted together.
  String testKey;
  String testName;
  double? value;

  /// For non-numeric results such as "Negative" or "Trace".
  String? valueText;
  String? unit;
  double? refLow;
  double? refHigh;

  /// Copied from the report so trends can be queried without a join.
  DateTime date;
  int updatedAt;

  ResultFlag get flag {
    final v = value;
    if (v == null || (refLow == null && refHigh == null)) return ResultFlag.unknown;
    if (refLow != null && v < refLow!) return ResultFlag.low;
    if (refHigh != null && v > refHigh!) return ResultFlag.high;
    return ResultFlag.normal;
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'report_id': reportId,
    'member_id': memberId,
    'test_key': testKey,
    'test_name': testName,
    'value': value,
    'value_text': valueText,
    'unit': unit,
    'ref_low': refLow,
    'ref_high': refHigh,
    'date': dateToDb(date),
    'updated_at': updatedAt,
  };

  factory TestResult.fromMap(Map<String, Object?> m) => TestResult(
    id: m['id'] as String,
    reportId: m['report_id'] as String,
    memberId: m['member_id'] as String,
    testKey: m['test_key'] as String,
    testName: m['test_name'] as String,
    value: (m['value'] as num?)?.toDouble(),
    valueText: m['value_text'] as String?,
    unit: m['unit'] as String?,
    refLow: (m['ref_low'] as num?)?.toDouble(),
    refHigh: (m['ref_high'] as num?)?.toDouble(),
    date: dateFromDb(m['date'] as String),
    updatedAt: m['updated_at'] as int,
  );
}

/// A course of medicine with daily dose times. [days] null means ongoing.
class Medication {
  Medication({
    String? id,
    required this.memberId,
    this.reportId,
    required this.name,
    this.dose,
    required this.times,
    required this.startDate,
    this.days,
    this.instructions,
    this.reminders = true,
    int? updatedAt,
  }) : id = id ?? newId(),
       updatedAt = updatedAt ?? _now();

  final String id;
  final String memberId;

  /// Prescription this came from, if any.
  String? reportId;
  String name;
  String? dose;

  /// Daily dose times as minutes after midnight, sorted.
  List<int> times;
  DateTime startDate;
  int? days;
  String? instructions;
  bool reminders;
  int updatedAt;

  /// Last day of the course (inclusive), or null if ongoing.
  DateTime? get endDate => days == null ? null : DateTime(startDate.year, startDate.month, startDate.day + days! - 1);

  int? get totalDoses => days == null ? null : days! * times.length;

  bool isFinishedOn(DateTime day) {
    final end = endDate;
    return end != null && DateTime(day.year, day.month, day.day).isAfter(end);
  }

  bool isActiveOn(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(DateTime(startDate.year, startDate.month, startDate.day)) && !isFinishedOn(d);
  }

  /// 1-based day number of the course on [day].
  int dayNumber(DateTime day) =>
      DateTime(
        day.year,
        day.month,
        day.day,
      ).difference(DateTime(startDate.year, startDate.month, startDate.day)).inDays +
      1;

  /// Scheduled dose times between [from] and [to] (inclusive).
  Iterable<DateTime> slotsBetween(DateTime from, DateTime to) sync* {
    var day = DateTime(from.year, from.month, from.day);
    final last = endDate;
    while (!day.isAfter(to)) {
      if (last != null && day.isAfter(last)) return;
      if (isActiveOn(day)) {
        for (final t in times) {
          final slot = DateTime(day.year, day.month, day.day, t ~/ 60, t % 60);
          if (!slot.isBefore(from) && !slot.isAfter(to)) yield slot;
        }
      }
      day = DateTime(day.year, day.month, day.day + 1);
    }
  }

  Map<String, Object?> toMap() => {
    'id': id,
    'member_id': memberId,
    'report_id': reportId,
    'name': name,
    'dose': dose,
    'times': times.join(','),
    'start_date': dateToDb(startDate),
    'days': days,
    'instructions': instructions,
    'reminders': reminders ? 1 : 0,
    'updated_at': updatedAt,
  };

  factory Medication.fromMap(Map<String, Object?> m) => Medication(
    id: m['id'] as String,
    memberId: m['member_id'] as String,
    reportId: m['report_id'] as String?,
    name: m['name'] as String,
    dose: m['dose'] as String?,
    times: [
      for (final t in (m['times'] as String).split(','))
        if (t.isNotEmpty) int.parse(t),
    ],
    startDate: dateFromDb(m['start_date'] as String),
    days: m['days'] as int?,
    instructions: m['instructions'] as String?,
    reminders: (m['reminders'] as int) == 1,
    updatedAt: m['updated_at'] as int,
  );
}

/// Records that a scheduled dose was taken.
class DoseLog {
  DoseLog({
    String? id,
    required this.medicationId,
    required this.memberId,
    required this.slot,
    int? takenAt,
    int? updatedAt,
  }) : id = id ?? newId(),
       takenAt = takenAt ?? _now(),
       updatedAt = updatedAt ?? _now();

  final String id;
  final String medicationId;
  final String memberId;
  final DateTime slot;
  final int takenAt;
  final int updatedAt;

  static String slotKey(DateTime s) =>
      '${dateToDb(s)}T${s.hour.toString().padLeft(2, '0')}:${s.minute.toString().padLeft(2, '0')}';

  Map<String, Object?> toMap() => {
    'id': id,
    'medication_id': medicationId,
    'member_id': memberId,
    'slot': slotKey(slot),
    'taken_at': takenAt,
    'updated_at': updatedAt,
  };

  factory DoseLog.fromMap(Map<String, Object?> m) => DoseLog(
    id: m['id'] as String,
    medicationId: m['medication_id'] as String,
    memberId: m['member_id'] as String,
    slot: DateTime.parse(m['slot'] as String),
    takenAt: m['taken_at'] as int,
    updatedAt: m['updated_at'] as int,
  );
}
