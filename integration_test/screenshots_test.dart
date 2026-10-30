// Walks the demo family through the README screens. Each stop prints
// `SHOT <name>` and holds still so tool/screenshots.sh can take a native capture
// (real status bar and window frame). Uses in-memory keys and separate storage,
// so real records and the keychain are never touched.
//   tool/screenshots.sh <flutter-device-id> <label>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:medi_archive/main.dart';

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

    await tester.pumpWidget(const MediArchiveApp());
    await settle(tester);
    await shot('home');

    final card = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('member-card-'));
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

    await tester.ensureVisible(find.textContaining('Medicines').first);
    await settle(tester, rounds: 3);
    await tester.tap(find.textContaining('Medicines').hitTestable().first);
    await settle(tester);
    await shot('medicines');
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
