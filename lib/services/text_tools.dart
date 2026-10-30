/// Small text helpers shared by the report parser and the AI checks.
library;

const _banglaDigits = '০১২৩৪৫৬৭৮৯';

/// Replaces Bengali digits with ASCII ones (`১+০+১` → `1+0+1`).
String asciiDigits(String s) {
  final out = StringBuffer();
  for (final c in s.runes) {
    final i = _banglaDigits.runes.toList().indexOf(c);
    out.write(i >= 0 ? '$i' : String.fromCharCode(c));
  }
  return out.toString();
}

/// Every number in [line], as values: `2,50,000` and `11.20` compare equal to
/// `250000` and `11.2`, however a reader spaced or grouped them.
Set<double> numbersIn(String line) {
  final text = asciiDigits(line);
  final out = <double>{};
  for (final m in RegExp(r'\d[\d,]*(?:\.\d+)?|\.\d+').allMatches(text)) {
    final v = double.tryParse(m[0]!.replaceAll(',', ''));
    if (v != null) out.add(v);
  }
  return out;
}

int editDistance(String a, String b) {
  var previous = List.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final row = [i];
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      final best = [previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost].reduce((x, y) => x < y ? x : y);
      row.add(best);
    }
    previous = row;
  }
  return previous[b.length];
}

/// Same name allowing one misread letter in longer words.
bool sameWord(String a, String b) => a == b || (a.length >= 5 && b.length >= 5 && editDistance(a, b) <= 1);
