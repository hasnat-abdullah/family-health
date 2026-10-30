import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:family_health/bootstrap.dart';
import 'package:family_health/data/database.dart';
import 'package:family_health/security/app_lock.dart';
import 'package:family_health/security/vault.dart';
import 'package:family_health/services/file_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'fixture_data.dart';

/// Biometric prompt stand-in.
class FakeAuthenticator implements Authenticator {
  bool available = true;
  bool succeed = true;
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<bool> authenticate(String reason) async {
    prompts++;
    return succeed;
  }
}

/// Isolated, encrypted storage per test so real records are never touched.
class TestStorage {
  TestStorage(String tag) : config = StorageConfig(dbName: 'test_$tag.db', filesFolder: 'test_${tag}_files');
  final StorageConfig config;
  final keyStore = MemoryKeyStore();

  Future<void> wipe() async {
    await deleteDatabase(await AppDb.pathFor(config.dbName));
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, config.filesFolder));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<String> get dbPath => AppDb.pathFor(config.dbName);
  Future<Directory> get filesDir async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, config.filesFolder));

  Future<void> boot({bool demo = false}) async {
    await bootstrap(config: config, keyStore: keyStore, seedDemoData: demo);
  }
}

Future<void> closeDb() async {
  try {
    await AppDb.instance.close();
  } catch (_) {}
}

void resetHooks() {
  FileIO.debugPick = null;
  FileIO.debugSave = null;
  AppLock.relockAfter = const Duration(minutes: 1);
}

Uint8List fixtureBytes(String name) => base64Decode(fixtureData[name]!);

/// Writes an embedded fixture to a fresh temp file, the way a picker hands over a copy.
Future<Picked> fixture(String name) async {
  final dir = await Directory(p.join((await getTemporaryDirectory()).path, 'picked')).create(recursive: true);
  final copy = File(p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}_$name'));
  await copy.writeAsBytes(fixtureBytes(name));
  return (file: copy, name: name);
}

/// Pumps frames while letting real async work (DB, isolates, crypto) finish.
Future<void> settle(WidgetTester tester, {int rounds = 15}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 60));
  }
  // Let page transitions finish so taps land where widgets end up. Screens
  // with a spinning progress indicator never settle, hence the short timeout.
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 50),
      EnginePhase.sendSemanticsUpdate,
      const Duration(seconds: 2),
    );
  } on FlutterError {
    // still animating (spinner) — fine
  }
}

/// Waits until [finder] matches, up to [timeout].
Future<void> waitFor(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) {
      final onScreen = find
          .byType(Text)
          .hitTestable()
          .evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .join(' | ');
      final all = find
          .byType(Text)
          .evaluate()
          .map((e) {
            final box = e.renderObject as RenderBox?;
            final at = box != null && box.hasSize ? box.localToGlobal(Offset.zero) : null;
            return '${(e.widget as Text).data}@${at?.dx.round()},${at?.dy.round()}';
          })
          .join(' | ');
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      throw TestFailure('Timed out waiting for $finder\nOn screen: $onScreen\nAll ($size): $all');
    }
    await settle(tester, rounds: 2);
  }
}

Future<void> tapText(WidgetTester tester, String text, {bool last = false}) async {
  final any = last ? find.text(text).last : find.text(text).first;
  await tester.ensureVisible(any);
  await settle(tester, rounds: 1);
  // Some widgets (e.g. SegmentedButton) also lay out invisible copies of a label.
  final visible = find.text(text).hitTestable();
  await tester.tap(last ? visible.last : visible.first);
  await settle(tester);
}

/// Text field inside the input decorated with [label].
Finder fieldLabeled(String label) => find.ancestor(of: find.text(label), matching: find.byType(TextField)).first;

/// Sets a text field's value directly (more reliable than simulated typing
/// when several obscured fields swap focus).
Future<void> setField(WidgetTester tester, Finder field, String text) async {
  final editable = tester.widget<EditableText>(find.descendant(of: field, matching: find.byType(EditableText)));
  editable.controller.text = text;
  await tester.pump();
}
