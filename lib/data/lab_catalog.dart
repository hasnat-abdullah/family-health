/// Known lab tests: canonical names, the aliases labs print, a canonical unit,
/// and typical adult reference ranges (used only when a report doesn't print its own).
///
/// Ranges here are general adult values for orientation, not medical advice —
/// the range printed on each report always takes precedence.
library;

class RefRange {
  const RefRange(this.low, this.high);
  final double? low;
  final double? high;
}

/// Converts a value printed in another unit/scale into the canonical unit.
/// [when] receives the raw value and the unit text as printed (lower-cased).
class ScaleRule {
  const ScaleRule(this.when, this.factor);
  final bool Function(double value, String unit) when;
  final double factor;
}

class LabTest {
  const LabTest({
    required this.key,
    required this.name,
    required this.panel,
    required this.aliases,
    required this.unit,
    this.range,
    this.female,
    this.male,
    this.scale = const [],
  });

  final String key;
  final String name;
  final String panel;
  final List<String> aliases;
  final String unit;
  final RefRange? range;
  final RefRange? female;
  final RefRange? male;
  final List<ScaleRule> scale;

  RefRange? rangeFor(String? sex) => switch (sex) {
    'F' => female ?? range,
    'M' => male ?? range,
    _ => range ?? female ?? male,
  };

  /// Returns the factor to bring a printed value into [unit], or 1.
  double factorFor(double value, String printedUnit) {
    final u = printedUnit.toLowerCase();
    for (final rule in scale) {
      if (rule.when(value, u)) return rule.factor;
    }
    return 1;
  }
}

bool _hasAny(String unit, List<String> parts) => parts.any(unit.contains);

// Cell counts are canonical in ×10⁹/L (= thousand per µL). Many labs print
// "/cumm" or "/µL" with the full count, e.g. WBC 7,500 or platelets 2,50,000.
final _perMicrolitre = [
  ScaleRule((v, u) => _hasAny(u, ['lakh', 'lac']), 100),
  ScaleRule((v, u) => v >= 1000, 0.001),
];

const _cbc = 'Complete Blood Count';
const _lipid = 'Lipid Profile';
const _sugar = 'Diabetes';
const _kidney = 'Kidney Function';
const _liver = 'Liver Function';
const _thyroid = 'Thyroid';
const _electrolytes = 'Electrolytes';
const _iron = 'Iron & Vitamins';
const _other = 'Other';

final List<LabTest> labCatalog = [
  // ---- CBC
  LabTest(
    key: 'hemoglobin', name: 'Hemoglobin', panel: _cbc, unit: 'g/dL',
    aliases: ['hemoglobin', 'haemoglobin', 'hb', 'hgb', 'hb%'],
    female: RefRange(12.0, 15.5), male: RefRange(13.5, 17.5),
    scale: [ScaleRule((v, u) => u.contains('g/l') && !u.contains('dl') || v > 30, 0.1)],
  ),
  LabTest(
    key: 'rbc', name: 'RBC Count', panel: _cbc, unit: '×10¹²/L',
    aliases: ['rbc count', 'total rbc count', 'total rbc', 'rbc', 'red blood cell count', 'red blood cells', 'red cell count', 'erythrocyte count', 'erythrocytes'],
    female: RefRange(4.0, 5.2), male: RefRange(4.5, 5.9),
    scale: [ScaleRule((v, u) => v >= 1000, 0.000001)],
  ),
  LabTest(
    key: 'hematocrit', name: 'Hematocrit (HCT/PCV)', panel: _cbc, unit: '%',
    aliases: ['hematocrit', 'haematocrit', 'hct', 'pcv', 'packed cell volume'],
    female: RefRange(36, 46), male: RefRange(41, 53),
    scale: [ScaleRule((v, u) => v < 1, 100)],
  ),
  LabTest(
    key: 'mcv', name: 'MCV', panel: _cbc, unit: 'fL',
    aliases: ['mcv', 'mean corpuscular volume', 'mean cell volume'],
    range: RefRange(80, 100),
  ),
  LabTest(
    key: 'mch', name: 'MCH', panel: _cbc, unit: 'pg',
    aliases: ['mch', 'mean corpuscular hemoglobin', 'mean corpuscular haemoglobin', 'mean cell hemoglobin', 'mean cell haemoglobin'],
    range: RefRange(27, 33),
  ),
  LabTest(
    key: 'mchc', name: 'MCHC', panel: _cbc, unit: 'g/dL',
    aliases: ['mchc', 'mean corpuscular hemoglobin concentration', 'mean corpuscular haemoglobin concentration', 'mean cell hemoglobin concentration', 'mean cell haemoglobin concentration'],
    range: RefRange(32, 36),
    scale: [ScaleRule((v, u) => v > 100, 0.1)],
  ),
  LabTest(
    key: 'rdw', name: 'RDW-CV', panel: _cbc, unit: '%',
    aliases: ['rdw-cv', 'rdw cv', 'rdw', 'red cell distribution width'],
    range: RefRange(11.5, 14.5),
  ),
  LabTest(
    key: 'wbc', name: 'WBC (Total Count)', panel: _cbc, unit: '×10⁹/L',
    aliases: ['total wbc count', 'wbc count', 'wbc', 'white blood cell count', 'white blood cells', 'white cell count', 'total leucocyte count', 'total leukocyte count', 'tlc', 'total count', 'tc', 'leucocytes', 'leukocytes'],
    range: RefRange(4.0, 11.0),
    scale: _perMicrolitre,
  ),
  LabTest(
    key: 'neutrophils', name: 'Neutrophils', panel: _cbc, unit: '%',
    aliases: ['neutrophils', 'neutrophil', 'neutrophil %', 'polymorphs', 'segmented neutrophils', 'neut'],
    range: RefRange(40, 75),
  ),
  LabTest(
    key: 'lymphocytes', name: 'Lymphocytes', panel: _cbc, unit: '%',
    aliases: ['lymphocytes', 'lymphocyte', 'lymph'],
    range: RefRange(20, 45),
  ),
  LabTest(
    key: 'monocytes', name: 'Monocytes', panel: _cbc, unit: '%',
    aliases: ['monocytes', 'monocyte', 'mono'],
    range: RefRange(2, 10),
  ),
  LabTest(
    key: 'eosinophils', name: 'Eosinophils', panel: _cbc, unit: '%',
    aliases: ['eosinophils', 'eosinophil', 'eos'],
    range: RefRange(1, 6),
  ),
  LabTest(
    key: 'basophils', name: 'Basophils', panel: _cbc, unit: '%',
    aliases: ['basophils', 'basophil', 'baso'],
    range: RefRange(0, 2),
  ),
  LabTest(
    key: 'anc', name: 'Absolute Neutrophil Count', panel: _cbc, unit: '×10⁹/L',
    aliases: ['absolute neutrophil count', 'absolute neutrophils', 'anc'],
    range: RefRange(1.5, 8.0),
    scale: _perMicrolitre,
  ),
  LabTest(
    key: 'alc', name: 'Absolute Lymphocyte Count', panel: _cbc, unit: '×10⁹/L',
    aliases: ['absolute lymphocyte count', 'absolute lymphocytes', 'alc'],
    range: RefRange(1.0, 4.0),
    scale: _perMicrolitre,
  ),
  LabTest(
    key: 'platelets', name: 'Platelet Count', panel: _cbc, unit: '×10⁹/L',
    aliases: ['platelet count', 'platelets', 'platelet', 'plt', 'thrombocytes', 'thrombocyte count'],
    range: RefRange(150, 450),
    scale: _perMicrolitre,
  ),
  LabTest(
    key: 'mpv', name: 'MPV', panel: _cbc, unit: 'fL',
    aliases: ['mpv', 'mean platelet volume'],
    range: RefRange(7.5, 11.5),
  ),
  LabTest(
    key: 'esr', name: 'ESR', panel: _cbc, unit: 'mm/hr',
    aliases: ['esr', 'erythrocyte sedimentation rate', 'e.s.r'],
    female: RefRange(0, 20), male: RefRange(0, 15),
  ),

  // ---- Diabetes
  LabTest(
    key: 'glucose_fasting', name: 'Fasting Glucose', panel: _sugar, unit: 'mmol/L',
    aliases: ['fasting blood sugar', 'fasting blood glucose', 'fasting plasma glucose', 'fasting glucose', 'fbs', 'fbg', 'fpg', 'glucose fasting', 'blood sugar fasting', 'blood sugar (fasting)'],
    range: RefRange(3.9, 5.5),
    scale: [ScaleRule((v, u) => u.contains('mg') || v > 35, 1 / 18.0)],
  ),
  LabTest(
    key: 'glucose_pp', name: 'Glucose 2h After Meal', panel: _sugar, unit: 'mmol/L',
    aliases: ['2 hours after breakfast', '2 hrs after breakfast', '2hr abf', '2h abf', 'post prandial blood sugar', 'postprandial glucose', 'ppbs', 'blood sugar 2 hrs abf', 'abf'],
    range: RefRange(null, 7.8),
    scale: [ScaleRule((v, u) => u.contains('mg') || v > 35, 1 / 18.0)],
  ),
  LabTest(
    key: 'glucose_random', name: 'Random Glucose', panel: _sugar, unit: 'mmol/L',
    aliases: ['random blood sugar', 'random blood glucose', 'random plasma glucose', 'rbs', 'rbg'],
    range: RefRange(null, 7.8),
    scale: [ScaleRule((v, u) => u.contains('mg') || v > 35, 1 / 18.0)],
  ),
  LabTest(
    key: 'hba1c', name: 'HbA1c', panel: _sugar, unit: '%',
    aliases: ['hba1c', 'hb a1c', 'glycated hemoglobin', 'glycated haemoglobin', 'glycosylated hemoglobin', 'glycosylated haemoglobin', 'a1c'],
    range: RefRange(null, 5.7),
  ),

  // ---- Lipids
  LabTest(
    key: 'cholesterol_total', name: 'Total Cholesterol', panel: _lipid, unit: 'mg/dL',
    aliases: ['total cholesterol', 'cholesterol total', 'serum cholesterol', 'cholesterol', 's. cholesterol'],
    range: RefRange(null, 200),
    scale: [ScaleRule((v, u) => u.contains('mmol') || v < 20, 38.67)],
  ),
  LabTest(
    key: 'ldl', name: 'LDL Cholesterol', panel: _lipid, unit: 'mg/dL',
    aliases: ['ldl cholesterol', 'ldl-c', 'ldl', 'low density lipoprotein'],
    range: RefRange(null, 100),
    scale: [ScaleRule((v, u) => u.contains('mmol') || v < 15, 38.67)],
  ),
  LabTest(
    key: 'hdl', name: 'HDL Cholesterol', panel: _lipid, unit: 'mg/dL',
    aliases: ['hdl cholesterol', 'hdl-c', 'hdl', 'high density lipoprotein'],
    range: RefRange(40, null),
    scale: [ScaleRule((v, u) => u.contains('mmol') || v < 5, 38.67)],
  ),
  LabTest(
    key: 'triglycerides', name: 'Triglycerides', panel: _lipid, unit: 'mg/dL',
    aliases: ['triglycerides', 'triglyceride', 'tg', 's. triglyceride'],
    range: RefRange(null, 150),
    scale: [ScaleRule((v, u) => u.contains('mmol') || v < 15, 88.57)],
  ),

  // ---- Kidney
  LabTest(
    key: 'creatinine', name: 'Creatinine', panel: _kidney, unit: 'mg/dL',
    aliases: ['serum creatinine', 's. creatinine', 's.creatinine', 'creatinine'],
    female: RefRange(0.5, 1.1), male: RefRange(0.7, 1.3),
    scale: [ScaleRule((v, u) => u.contains('mol') || v > 20, 1 / 88.4)],
  ),
  LabTest(
    key: 'urea', name: 'Blood Urea', panel: _kidney, unit: 'mg/dL',
    aliases: ['blood urea', 'serum urea', 'urea'],
    range: RefRange(15, 40),
  ),
  LabTest(
    key: 'bun', name: 'BUN', panel: _kidney, unit: 'mg/dL',
    aliases: ['blood urea nitrogen', 'bun'],
    range: RefRange(7, 20),
  ),
  LabTest(
    key: 'uric_acid', name: 'Uric Acid', panel: _kidney, unit: 'mg/dL',
    aliases: ['serum uric acid', 'uric acid'],
    female: RefRange(2.4, 6.0), male: RefRange(3.4, 7.0),
  ),
  LabTest(
    key: 'egfr', name: 'eGFR', panel: _kidney, unit: 'mL/min/1.73m²',
    aliases: ['egfr', 'estimated gfr'],
    range: RefRange(90, null),
  ),

  // ---- Liver
  LabTest(
    key: 'alt', name: 'ALT (SGPT)', panel: _liver, unit: 'U/L',
    aliases: ['alt', 'sgpt', 'alt (sgpt)', 'sgpt (alt)', 'alanine aminotransferase', 'alanine transaminase'],
    range: RefRange(null, 40),
  ),
  LabTest(
    key: 'ast', name: 'AST (SGOT)', panel: _liver, unit: 'U/L',
    aliases: ['ast', 'sgot', 'ast (sgot)', 'sgot (ast)', 'aspartate aminotransferase', 'aspartate transaminase'],
    range: RefRange(null, 40),
  ),
  LabTest(
    key: 'alp', name: 'Alkaline Phosphatase', panel: _liver, unit: 'U/L',
    aliases: ['alkaline phosphatase', 'alp'],
    range: RefRange(44, 147),
  ),
  LabTest(
    key: 'bilirubin_total', name: 'Total Bilirubin', panel: _liver, unit: 'mg/dL',
    aliases: ['total bilirubin', 'bilirubin total', 'serum bilirubin', 'bilirubin'],
    range: RefRange(0.1, 1.2),
    scale: [ScaleRule((v, u) => u.contains('mol') || v > 20, 1 / 17.1)],
  ),
  LabTest(
    key: 'albumin', name: 'Albumin', panel: _liver, unit: 'g/dL',
    aliases: ['serum albumin', 'albumin'],
    range: RefRange(3.5, 5.0),
    scale: [ScaleRule((v, u) => u.contains('g/l') && !u.contains('dl') || v > 10, 0.1)],
  ),

  // ---- Thyroid
  LabTest(
    key: 'tsh', name: 'TSH', panel: _thyroid, unit: 'mIU/L',
    aliases: ['tsh', 'thyroid stimulating hormone', 's. tsh'],
    range: RefRange(0.4, 4.0),
  ),
  LabTest(
    key: 'ft4', name: 'Free T4', panel: _thyroid, unit: 'ng/dL',
    aliases: ['free t4', 'ft4', 'free thyroxine'],
    range: RefRange(0.8, 1.8),
    scale: [ScaleRule((v, u) => u.contains('pmol') || v > 5, 1 / 12.87)],
  ),
  LabTest(
    key: 'ft3', name: 'Free T3', panel: _thyroid, unit: 'pg/mL',
    aliases: ['free t3', 'ft3', 'free triiodothyronine'],
    range: RefRange(2.3, 4.2),
  ),

  // ---- Electrolytes
  LabTest(
    key: 'sodium', name: 'Sodium', panel: _electrolytes, unit: 'mmol/L',
    aliases: ['serum sodium', 'sodium', 'na+', 'na'],
    range: RefRange(135, 145),
  ),
  LabTest(
    key: 'potassium', name: 'Potassium', panel: _electrolytes, unit: 'mmol/L',
    aliases: ['serum potassium', 'potassium', 'k+'],
    range: RefRange(3.5, 5.1),
  ),
  LabTest(
    key: 'chloride', name: 'Chloride', panel: _electrolytes, unit: 'mmol/L',
    aliases: ['serum chloride', 'chloride', 'cl-'],
    range: RefRange(98, 107),
  ),
  LabTest(
    key: 'calcium', name: 'Calcium', panel: _electrolytes, unit: 'mg/dL',
    aliases: ['serum calcium', 'total calcium', 'calcium'],
    range: RefRange(8.5, 10.5),
    scale: [ScaleRule((v, u) => u.contains('mmol') || v < 4, 4.008)],
  ),

  // ---- Iron & vitamins
  LabTest(
    key: 'ferritin', name: 'Ferritin', panel: _iron, unit: 'ng/mL',
    aliases: ['serum ferritin', 'ferritin'],
    female: RefRange(15, 150), male: RefRange(30, 400),
  ),
  LabTest(
    key: 'iron', name: 'Serum Iron', panel: _iron, unit: 'µg/dL',
    aliases: ['serum iron', 'iron'],
    range: RefRange(60, 170),
  ),
  LabTest(
    key: 'vitamin_d', name: 'Vitamin D (25-OH)', panel: _iron, unit: 'ng/mL',
    aliases: ['25-oh vitamin d', '25 oh vitamin d', 'vitamin d3', 'vitamin d', 'vit d', '25-hydroxy vitamin d'],
    range: RefRange(30, 100),
    scale: [ScaleRule((v, u) => u.contains('nmol'), 0.4)],
  ),
  LabTest(
    key: 'vitamin_b12', name: 'Vitamin B12', panel: _iron, unit: 'pg/mL',
    aliases: ['vitamin b12', 'vit b12', 'b12', 'cobalamin'],
    range: RefRange(200, 900),
  ),

  // ---- Other
  LabTest(
    key: 'crp', name: 'CRP', panel: _other, unit: 'mg/L',
    aliases: ['c-reactive protein', 'c reactive protein', 'crp', 'hs-crp'],
    range: RefRange(null, 5),
  ),
];

final Map<String, LabTest> labByKey = {for (final t in labCatalog) t.key: t};

/// Panels in display order.
const panelOrder = [_cbc, _sugar, _lipid, _kidney, _liver, _thyroid, _electrolytes, _iron, _other, 'Custom'];

String panelFor(String testKey) => labByKey[testKey]?.panel ?? 'Custom';

String customKey(String name) =>
    'custom:${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '')}';

/// Finds a catalog test by display name or alias (case-insensitive, exact).
LabTest? findTest(String name) {
  final n = name.trim().toLowerCase();
  for (final t in labCatalog) {
    if (t.name.toLowerCase() == n || t.key == n || t.aliases.contains(n)) return t;
  }
  return null;
}

/// Display order of test keys within a panel: catalog order, then custom by name.
int compareTestKeys(String a, String b) {
  final ia = labCatalog.indexWhere((t) => t.key == a);
  final ib = labCatalog.indexWhere((t) => t.key == b);
  if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
  if (ia >= 0) return -1;
  if (ib >= 0) return 1;
  return a.compareTo(b);
}
