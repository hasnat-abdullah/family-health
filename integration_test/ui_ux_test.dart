// UI/UX checks on every main screen, for phone/tablet, light/dark and large text:
// tap-target sizes (Android 48dp, iOS 44pt), labelled buttons, text contrast,
// and layout overflow. Saves screenshots to the app's caches folder.
//   flutter test integration_test/ui_ux_test.dart -d macos
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:family_health/main.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'harness.dart';

class _Config {
  const _Config(this.name, this.size, {this.dark = false, this.textScale = 1.0, this.a11y = true});
  final String name;

  /// Logical size; null keeps the device's own screen and safe areas.
  final Size? size;
  final bool dark;
  final double textScale;
  final bool a11y;
}

const _configs = [
  _Config('native', null),
  _Config('phone_light', Size(390, 844)),
  _Config('phone_dark', Size(390, 844), dark: true),
  // Large text: layout must not overflow (guidelines checked at 1×).
  _Config('phone_text200', Size(390, 844), textScale: 2.0, a11y: false),
  _Config('tablet_light', Size(1024, 1366)),
];

/// Member tabs scroll on phones, so bring the tab on screen first.
Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.textContaining(label).first);
  await settle(tester, rounds: 3);
  await tester.tap(find.textContaining(label).hitTestable().first);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('UI/UX guidelines on all main screens', (tester) async {
    addTearDown(resetHooks);
    final storage = TestStorage('uiux');
    await storage.wipe();
    await storage.boot(demo: true);
    final out = await Directory(p.join((await getTemporaryDirectory()).path, 'uiux')).create(recursive: true);
    final issues = <String>[];
    // ignore: avoid_print
    print('UI/UX running on ${Platform.operatingSystem}');
    var current = '';
    final originalOnError = FlutterError.onError;
    // Record every layout error (with its source line) instead of stopping at the first.
    FlutterError.onError = (details) {
      final where = RegExp(r'lib/[\w/]+\.dart:\d+').firstMatch(details.toString())?.group(0) ?? '';
      issues.add('[$current] ${details.exceptionAsString().split('\n').first} $where');
    };

    for (final c in _configs) {
      try {
        if (c.size == null) {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        } else {
          tester.view.physicalSize = c.size! * 2;
          tester.view.devicePixelRatio = 2;
        }
        binding.platformDispatcher.platformBrightnessTestValue = c.dark ? Brightness.dark : Brightness.light;
        binding.platformDispatcher.textScaleFactorTestValue = c.textScale;

        final key = GlobalKey();
        await tester.pumpWidget(const SizedBox());
        current = '${c.name}/01_home';
        await tester.pumpWidget(RepaintBoundary(key: key, child: const FamilyHealthApp()));
        await settle(tester);

        Future<void> check(String screen) async {
          current = '${c.name}/$screen';
          // ignore: avoid_print
          print('CHECK $current');
          await settle(tester, rounds: 6);
          final ex = tester.takeException();
          if (ex != null) issues.add('[${c.name}] $screen: ${ex.toString().split('\n').first}');
          if (c.a11y) {
            for (final (label, g) in [
              ('android tap target', androidTapTargetGuideline),
              ('iOS tap target', iOSTapTargetGuideline),
              ('labeled tap target', labeledTapTargetGuideline),
              ('text contrast', textContrastGuideline),
            ]) {
              final result = await g.evaluate(tester);
              if (!result.passed) {
                issues.add('[${c.name}] $screen · $label:\n    ${result.reason?.trim().replaceAll('\n', '\n    ')}');
              }
            }
          }
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(p.join(out.path, '${c.name}_$screen.png')).writeAsBytes(bytes!.buffer.asUint8List());
          });
        }

        Future<void> back() async {
          await tester.pageBack();
          await settle(tester);
        }

        await check('01_home');

        final card = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key! as ValueKey).value}'.startsWith('member-card-'));
        final nadia = find.descendant(of: card, matching: find.text('Nadia Rahman'));
        await tester.scrollUntilVisible(nadia, 200, scrollable: find.byType(Scrollable).first);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -200)); // clear of the FAB
        await settle(tester, rounds: 3);
        await tester.tap(nadia.hitTestable());
        await settle(tester);
        await check('02_member_health');

        await tester.tap(find.text('Hemoglobin').hitTestable().first);
        await settle(tester);
        await check('03_trend');
        await back();

        await tapTab(tester, 'Documents');
        await settle(tester);
        await check('04_documents');

        await tester.tap(find.widgetWithText(ListTile, 'CBC').first);
        await settle(tester);
        await check('05_report');
        await back();

        await tapTab(tester, 'Medicines');
        await settle(tester);
        await check('06_medicines');

        await tester.tap(find.widgetWithText(FloatingActionButton, 'Add'));
        await settle(tester);
        await check('07_add_sheet');
        await tester.tap(find.text('Enter values manually').hitTestable());
        await settle(tester);
        await check('08_editor');
        await back();

        await tester.tap(find.widgetWithText(FloatingActionButton, 'Add'));
        await settle(tester);
        await tester.scrollUntilVisible(find.text('Medicine reminder'), 100, scrollable: find.byType(Scrollable).last);
        await tester.tap(find.text('Medicine reminder').hitTestable());
        await settle(tester);
        await check('09_medicine_form');
        await back();

        await back();
        await tester.tap(find.byTooltip('Security & backup'));
        await settle(tester);
        await check('10_security');
        await tester.scrollUntilVisible(find.text('Whole family'), 150, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.text('Whole family').hitTestable());
        await settle(tester);
        await check('11_password_dialog');
        await tester.tap(find.text('Cancel').hitTestable());
        await settle(tester);
        await tester.scrollUntilVisible(find.text('AI document reading'), 150, scrollable: find.byType(Scrollable).first);
        await settle(tester, rounds: 3);
        await tester.tap(find.text('AI document reading').hitTestable());
        await settle(tester);
        await check('12_ai_settings');
        await back();
        await back();

        await tester.tap(find.byTooltip('Doctors'));
        await settle(tester);
        await check('13_doctors');
        await tester.tap(find.text('Dr. Abdul Karim').hitTestable().first);
        await settle(tester);
        await check('14_doctor_detail');
        await back();
        await back();
      } catch (e) {
        // Keep going: the other configurations still get checked.
        issues.add('[$current] step failed: ${e.toString().split('\n').first}');
      }
    }
    // Restored here, not in a tear-down: the framework hangs if a test fails
    // while its error handler is replaced.
    FlutterError.onError = originalOnError;

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    binding.platformDispatcher.clearAllTestValues();
    await tester.pumpWidget(const SizedBox());
    await closeDb();
    await storage.wipe();

    // ignore: avoid_print
    print('UI/UX: ${issues.length} issue(s); screenshots in ${out.path}\n${issues.join('\n')}');
    expect(issues, isEmpty);
  });
}
