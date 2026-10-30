// End-to-end check of on-device report reading (native OCR / PDF text + parser).
//   flutter test integration_test/report_reading_test.dart -d <device>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medi_archive/services/report_parser.dart';
import 'package:medi_archive/services/report_reader.dart';
import 'package:pdfrx/pdfrx.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<ParsedReport> read(String name) async {
    pdfrxFlutterInitialize();
    final picked = await fixture(name);
    final lines = await ReportReader.readLines(picked.file);
    // ignore: avoid_print
    print('--- $name\n${lines.join('\n')}');
    return ReportParser(sex: 'F').parse(lines);
  }

  double? value(ParsedReport r, String key) => r.results.where((x) => x.testKey == key).firstOrNull?.value;

  testWidgets('photo via OCR', (_) async {
    final r = await read('cbc_photo.jpg');
    expect(r.date, DateTime(2025, 9, 12));
    expect(value(r, 'hemoglobin'), 10.8);
    expect(value(r, 'wbc'), 8.2);
    expect(value(r, 'platelets'), 210);
    expect(value(r, 'mcv'), 76.2);
    expect(value(r, 'esr'), 32);
  });

  testWidgets('PDF with text layer', (_) async {
    final r = await read('cbc_text.pdf');
    expect(r.date, DateTime(2025, 10, 2));
    expect(value(r, 'hemoglobin'), 11.6);
    expect(value(r, 'wbc'), 7.9);
    expect(value(r, 'platelets'), 240);
  });

  testWidgets('scanned PDF via render + OCR', (_) async {
    final r = await read('cbc_scanned.pdf');
    expect(value(r, 'hemoglobin'), 10.8);
    expect(value(r, 'platelets'), 210);
  });
}
