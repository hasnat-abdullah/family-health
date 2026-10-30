// Walks the demo family through the README screens. Each stop prints
// `SHOT <name>` and holds still so tool/screenshots.sh can take a native capture
// (real status bar and window frame). Uses in-memory keys and separate storage,
// so real records and the keychain are never touched.
//   tool/screenshots.sh <flutter-device-id> <label>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:family_health/main.dart';
import 'package:family_health/services/file_io.dart';

import 'harness.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('README screenshots', (tester) async {
    addTearDown(resetHooks);
    final storage = TestStorage('screens');
    await storage.wipe();
    await storage.boot(demo: true);

    Future<void> shot(String name) async {
      await settle(tester, rounds: 6);
      // ignore: avoid_print
      print('SHOT $name');
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    }

    Future<void> back() async {
      await tester.pageBack();
      await settle(tester);
    }

    await tester.pumpWidget(const FamilyHealthApp());
    await settle(tester);
    await shot('home');

    final card = find.byWidgetPredicate(
      (w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('member-card-'),
    );
    final nadia = find.descendant(of: card, matching: find.text('Nadia Rahman'));
    await tester.scrollUntilVisible(nadia, 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200)); // clear of the FAB
    await settle(tester, rounds: 3);
    await tester.tap(nadia.hitTestable());
    await settle(tester);
    await shot('member');

    await tester.tap(find.text('Hemoglobin').hitTestable().first);
    await settle(tester);
    await shot('trend');
    await back();

    // Automatic reading: a photographed CBC is read on the device, then reviewed.
    // Nothing is saved, so the charts below keep the demo data.
    Finder fab(String label) => find.widgetWithText(FloatingActionButton, label);
    Future<void> reveal(Finder f) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await settle(tester, rounds: 2);
      await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
      await settle(tester, rounds: 2);
    }

    Future<void> discard() async {
      await tester.pageBack();
      await settle(tester);
      await tapText(tester, 'Discard');
    }

    final photo = await fixture('cbc_photo.jpg');
    FileIO.debugPick = (_) async => [photo];
    await tester.tap(fab('Add'));
    await settle(tester);
    await shot('add');
    await tester.tap(find.textContaining('PDF or image').hitTestable().first);
    await waitFor(tester, find.textContaining('Found'));
    await shot('import_review');
    await reveal(find.byWidgetPredicate((w) => w is TextField && w.controller?.text == '10.8'));
    await shot('import_values');
    await discard();

    // Data entry: typing a monthly CBC by hand.
    await tester.tap(fab('Add'));
    await settle(tester);
    await tapText(tester, 'Enter values manually');
    Finder valueFor(String test) => find.descendant(
      of: find.ancestor(of: find.text(test), matching: find.byType(Row)).first,
      matching: find.byType(TextField),
    );
    await reveal(find.text('Hemoglobin'));
    await tester.enterText(valueFor('Hemoglobin'), '12.6');
    await reveal(find.text('ESR'));
    await tester.enterText(valueFor('ESR'), '35');
    await settle(tester, rounds: 3);
    await shot('manual_entry');
    await discard();

    await tester.tap(fab('Add'));
    await settle(tester);
    await tapText(tester, 'Medicine reminder');
    await tester.enterText(fieldLabeled('Medicine name'), 'Ferrous sulfate');
    await tester.enterText(fieldLabeled('Dose (optional)'), '200 mg');
    await settle(tester, rounds: 3);
    await shot('medicine_form');
    await back();

    await tester.ensureVisible(find.textContaining('Medicines').first);
    await settle(tester, rounds: 3);
    await tester.tap(find.textContaining('Medicines').hitTestable().first);
    await settle(tester);
    await shot('medicines');
    await back();

    await tester.tap(find.byTooltip('Security & backup'));
    await settle(tester);
    await shot('backup');
    await tapText(tester, 'AI document reading');
    await shot('ai_settings');
    await back();

    await tester.tap(find.byTooltip('Doctors'));
    await settle(tester);
    await tester.tap(find.text('Dr. Abdul Karim').hitTestable().first);
    await settle(tester);
    await shot('doctor');
    await back();
    await back();

    binding.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.scrollUntilVisible(nadia, 200, scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
    await settle(tester, rounds: 3);
    await tester.tap(nadia.hitTestable());
    await settle(tester);
    await tester.tap(find.text('Hemoglobin').hitTestable().first);
    await settle(tester);
    await shot('trend_dark');

    binding.platformDispatcher.clearAllTestValues();
    await tester.pumpWidget(const SizedBox());
    await closeDb();
  });
}
