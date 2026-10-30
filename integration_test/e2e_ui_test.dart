// End-to-end through the real UI on encrypted test storage.
//   flutter test integration_test/e2e_ui_test.dart -d macos
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:family_health/main.dart';
import 'package:family_health/security/app_lock.dart';
import 'package:family_health/security/vault.dart';
import 'package:family_health/services/file_io.dart';
import 'package:family_health/widgets/attachment_strip.dart';
import 'package:family_health/widgets/common.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Finder fab(String label) => find.widgetWithText(FloatingActionButton, label);
  Finder valueFieldFor(String test) =>
      find.descendant(of: find.ancestor(of: find.text(test), matching: find.byType(Row)).first, matching: find.byType(TextField));
  Finder fieldWithValue(String v) => find.byWidgetPredicate((w) => w is TextField && w.controller?.text == v);
  Future<void> reveal(WidgetTester tester, Finder f) async {
    // A focused field pulls the list back to itself.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(tester, rounds: 2);
    await tester.scrollUntilVisible(f, 150, scrollable: find.byType(Scrollable).first);
    await settle(tester, rounds: 2);
  }

  Finder inAttention(String text) => find.descendant(of: find.byType(AttentionCard), matching: find.text(text));

  testWidgets('family records from first launch to restore on a new device', (tester) async {
    addTearDown(resetHooks);
    final auth = FakeAuthenticator();
    AppLock.authenticator = auth;

    final device1 = TestStorage('e2e');
    await device1.wipe();
    await device1.boot();
    await tester.pumpWidget(const FamilyHealthApp());
    await settle(tester);

    // ---- 1. First run → add a member.
    expect(find.text('Start with your family'), findsOneWidget);
    await tapText(tester, 'Add first member');
    await tester.enterText(fieldLabeled('Name'), 'Nadia Rahman');
    await tapText(tester, 'Female');
    expect(tester.widget<SegmentedButton<String?>>(find.byType(SegmentedButton<String?>)).selected, {'F'});
    await tapText(tester, 'Save');
    expect(find.text('Nadia Rahman'), findsOneWidget);
    expect(find.text('No records yet'), findsOneWidget);

    // ---- 2. Import a photographed CBC: OCR → review → save.
    await tapText(tester, 'Nadia Rahman');
    expect(find.text('No results yet'), findsOneWidget);
    final photo = await fixture('cbc_photo.jpg');
    FileIO.debugPick = (_) async => [photo];
    await tester.tap(fab('Add'));
    await settle(tester);
    await tapText(tester, isMobile ? 'Choose a PDF or image file' : 'Import PDF or image');
    await waitFor(tester, find.textContaining('Found'));
    expect(find.textContaining('Please check them against the original'), findsOneWidget);
    await reveal(tester, fieldWithValue('10.8'));
    expect(fieldWithValue('10.8'), findsOneWidget, reason: 'hemoglobin read from the photo');
    await reveal(tester, fieldWithValue('210'));
    expect(fieldWithValue('210'), findsOneWidget, reason: 'platelets 2,10,000/cumm → 210 ×10⁹/L');
    await tester.scrollUntilVisible(find.text('Sep 12, 2025'), -150, scrollable: find.byType(Scrollable).first);
    expect(find.text('Sep 12, 2025'), findsOneWidget, reason: 'report date read from the photo');
    expect(await photo.file.exists(), isFalse, reason: 'plain picker copy removed once encrypted');
    await tapText(tester, 'Save');
    await waitFor(tester, find.text('Needs attention'));
    expect(inAttention('Hemoglobin'), findsOneWidget);
    expect(inAttention('ESR'), findsOneWidget);
    expect(find.descendant(of: find.byType(AttentionCard), matching: find.text('Low')), findsWidgets);

    // ---- 3. This month's CBC typed in by hand: hemoglobin back to normal.
    await tester.tap(fab('Add'));
    await settle(tester);
    await tapText(tester, 'Enter values manually');
    await reveal(tester, find.text('Hemoglobin')); // CBC panel pre-filled for manual entry
    await tester.enterText(valueFieldFor('Hemoglobin'), '12.6');
    await reveal(tester, find.text('ESR'));
    await tester.enterText(valueFieldFor('ESR'), '35');
    await reveal(tester, find.text('Rows left empty are not saved.'));
    await settle(tester, rounds: 3);
    expect(find.text('Rows left empty are not saved.'), findsOneWidget);
    await tapText(tester, 'Save');
    await waitFor(tester, find.text('Needs attention'));
    expect(inAttention('Hemoglobin'), findsNothing, reason: 'latest hemoglobin is in range');
    expect(inAttention('ESR'), findsOneWidget);

    // ---- 4. Trend for hemoglobin.
    await tester.tap(find.text('Hemoglobin').first);
    await settle(tester);
    expect(find.text('Out of range'), findsWidgets);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('12.6'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);

    // ---- 5. Prescription → medicine with reminders → mark a dose.
    await tester.tap(fab('Add'));
    await settle(tester);
    await tapText(tester, 'Prescription');
    await tapText(tester, 'No file — just notes');
    expect(find.text('After saving you can add the medicines and set reminders.'), findsOneWidget);
    await tester.enterText(fieldLabeled('Notes (optional)'), 'Iron for 1 week, repeat CBC');
    await tapText(tester, 'Save');
    expect(find.textContaining('Prescription saved'), findsOneWidget);
    await tester.enterText(fieldLabeled('Medicine name'), 'Ferrous sulfate');
    await tester.enterText(fieldLabeled('Dose (optional)'), '200 mg');
    expect(find.textContaining('14 doses in total'), findsOneWidget);
    await tapText(tester, 'Save');
    await tapText(tester, 'Medicines (1)');
    expect(find.text('Ferrous sulfate · 200 mg'), findsWidgets);
    expect(find.text('0 of 14 doses taken'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await settle(tester);
    expect(find.text('1 of 2 taken'), findsOneWidget);
    expect(find.text('1 of 14 doses taken'), findsOneWidget);

    // ---- 6. Encrypted export from Security & backup.
    await tester.pageBack();
    await settle(tester);
    await tester.tap(find.byTooltip('Security & backup'));
    await settle(tester);
    expect(find.text('Your records are encrypted'), findsOneWidget);
    Uint8List? exported;
    FileIO.debugSave = (name, bytes) async {
      exported = bytes;
      return true;
    };
    await tapText(tester, 'Whole family');
    await setField(tester, find.byKey(const ValueKey('backup-password')), 'short');
    await setField(tester, find.byKey(const ValueKey('backup-password-confirm')), 'short');
    await tapText(tester, 'Encrypt & export');
    expect(find.text('Use at least 8 characters'), findsOneWidget);
    await setField(tester, find.byKey(const ValueKey('backup-password')), 'family-secret-1');
    await setField(tester, find.byKey(const ValueKey('backup-password-confirm')), 'family-secret-2');
    await tapText(tester, 'Encrypt & export');
    expect(find.text("Passwords don't match"), findsOneWidget);
    await setField(tester, find.byKey(const ValueKey('backup-password-confirm')), 'family-secret-1');
    await tapText(tester, 'Encrypt & export');
    await waitFor(tester, find.text('Encrypted backup exported.'));
    expect(exported, isNotNull);
    expect(Vault.isEncryptedBackup(exported!), isTrue);

    // ---- 7. App lock.
    await tester.scrollUntilVisible(find.text('App lock'), -150, scrollable: find.byType(Scrollable).first);
    await settle(tester, rounds: 2);
    await tester.tap(find.widgetWithText(SwitchListTile, 'App lock'));
    await settle(tester);
    expect(AppLock.enabled, isTrue);
    expect(auth.prompts, 1, reason: 'turning the lock on asks for authentication');
    AppLock.relockAfter = Duration.zero;
    auth.succeed = false;
    AppLock.onHidden();
    await settle(tester, rounds: 3);
    expect(find.text('Family Health is locked'), findsOneWidget, reason: 'content covered in the app switcher');
    AppLock.onVisible();
    await settle(tester);
    expect(find.text("Couldn't verify it's you. Try again."), findsOneWidget);
    auth.succeed = true;
    await tapText(tester, 'Unlock');
    expect(find.text('Family Health is locked'), findsNothing);
    expect(find.text('App lock'), findsOneWidget, reason: 'back where we were');

    // ---- 8. New device: import the backup with the password.
    await tester.pumpWidget(const SizedBox());
    await closeDb();
    final device2 = TestStorage('e2e2');
    await device2.wipe();
    await device2.boot();
    await tester.pumpWidget(const FamilyHealthApp());
    await settle(tester);
    expect(AppLock.enabled, isFalse, reason: 'lock setting is per device');
    expect(find.text('Start with your family'), findsOneWidget);

    final dir = await Directory(p.join((await getTemporaryDirectory()).path, 'picked')).create(recursive: true);
    final backupFile = File(p.join(dir.path, 'family.medarchive'));
    await backupFile.writeAsBytes(exported!);
    FileIO.debugPick = (_) async => [(file: backupFile, name: 'family.medarchive')];
    await tester.tap(find.byTooltip('Security & backup'));
    await settle(tester);
    await tapText(tester, 'Import a backup');
    await setField(tester, find.byKey(const ValueKey('backup-password')), 'not-the-password');
    await tapText(tester, 'Unlock');
    await waitFor(tester, find.text('Wrong password — try again'));
    await setField(tester, find.byKey(const ValueKey('backup-password')), 'family-secret-1');
    await tapText(tester, 'Unlock');
    await waitFor(tester, find.text('Import complete'));
    expect(find.textContaining('1 member profile(s)'), findsOneWidget);
    expect(find.textContaining('1 medicine(s)'), findsOneWidget);
    expect(find.textContaining('1 original file(s)'), findsOneWidget);
    await tapText(tester, 'OK');
    await tester.pageBack();
    await settle(tester);

    await tapText(tester, 'Nadia Rahman', last: true);
    expect(inAttention('ESR'), findsOneWidget);
    await tapText(tester, 'Documents (3)');
    await tester.tap(find.widgetWithText(ListTile, 'Prescription').first);
    await settle(tester);
    expect(find.text('Iron for 1 week, repeat CBC'), findsOneWidget, reason: 'prescription notes survived the backup');
    await reveal(tester, find.text('1 of 14 doses taken'));
    expect(find.text('Ferrous sulfate · 200 mg'), findsOneWidget);
    expect(find.text('1 of 14 doses taken'), findsOneWidget);
    await tester.pageBack();
    await settle(tester);
    // The photographed report: original decrypts and displays.
    final cbcTiles = find.widgetWithText(ListTile, 'CBC');
    await tester.tap(cbcTiles.last);
    await settle(tester);
    await waitFor(tester, find.descendant(of: find.byType(AttachmentStrip), matching: find.byType(Image)));
    expect(find.text('10.8 g/dL', findRichText: true), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await closeDb();
    await device1.wipe();
    await device2.wipe();
  });
}
