// Platform services that only exist on a real OS: the secure key store and
// scheduled notifications.
//   flutter test integration_test/device_services_test.dart -d <device>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:family_health/data/database.dart';
import 'package:family_health/data/models.dart';
import 'package:family_health/security/vault.dart';
import 'package:family_health/services/reminders.dart';

import 'harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('secure key store round trip', (_) async {
    final store = SecureKeyStore();
    const name = 'medi_archive.test_only';
    await store.delete(name);
    expect(await store.read(name), isNull);
    await store.write(name, 'value-1');
    expect(await store.read(name), 'value-1');
    await store.write(name, 'value-2');
    expect(await store.read(name), 'value-2');
    await store.delete(name);
    expect(await store.read(name), isNull);
  });

  testWidgets('reminders follow the course: schedule, taken, end, delete', (_) async {
    final storage = TestStorage('reminders');
    await storage.wipe();
    await storage.boot();
    final db = AppDb.instance;
    await Reminders.init();
    await Reminders.grantProvisionalForTest();

    final member = Member(name: 'Nadia', colorValue: 1);
    await db.saveMember(member);
    final now = DateTime.now();
    // A course that started yesterday with three dose times a day, 3 days long.
    final med = Medication(
      memberId: member.id,
      name: 'Amoxicillin',
      times: const [1, 12 * 60, 23 * 60 + 58],
      startDate: DateTime(now.year, now.month, now.day - 1),
      days: 3,
    );
    await db.saveMedication(med);
    await Reminders.reschedule();

    final expected = med.slotsBetween(now, now.add(const Duration(days: 14))).toList();
    // ignore: avoid_print
    print('REMINDERS expected=${expected.length} pending=${await Reminders.pendingCount()}');
    expect(expected.length, inInclusiveRange(3, 6), reason: 'nothing past the last day of the course');
    expect(await Reminders.pendingCount(), expected.length);

    // Marking a future dose as taken cancels just that reminder.
    await db.setTaken(med, expected.first, true);
    await Reminders.reschedule();
    expect(await Reminders.pendingCount(), expected.length - 1);

    // Reminders off.
    med.reminders = false;
    await db.saveMedication(med);
    await Reminders.reschedule();
    expect(await Reminders.pendingCount(), 0);

    // Stays inside the iOS limit of 64 however many medicines are active.
    final many = [
      for (var i = 0; i < 8; i++)
        Medication(memberId: member.id, name: 'Long term $i', times: const [8 * 60, 14 * 60, 20 * 60], startDate: now),
    ];
    for (final m in many) {
      await db.saveMedication(m);
    }
    await Reminders.reschedule();
    expect(await Reminders.pendingCount(), 60);

    // Deleting everything clears the schedule.
    await db.deleteMember(member.id);
    await Reminders.reschedule();
    expect(await Reminders.pendingCount(), 0);

    await closeDb();
    await storage.wipe();
  });

  testWidgets('a scheduled reminder actually arrives', timeout: const Timeout(Duration(minutes: 8)), (_) async {
    final storage = TestStorage('reminder_fire');
    await storage.wipe();
    await storage.boot();
    final db = AppDb.instance;
    await Reminders.init();
    await Reminders.grantProvisionalForTest();

    final member = Member(name: 'Nadia', colorValue: 1);
    await db.saveMember(member);
    final soon = DateTime.now().add(const Duration(minutes: 2));
    final med = Medication(
      memberId: member.id,
      name: 'Fire test',
      dose: '1 tablet',
      times: [soon.hour * 60 + soon.minute],
      startDate: DateTime(soon.year, soon.month, soon.day),
      days: 1,
    );
    await db.saveMedication(med);
    await Reminders.reschedule();
    expect(await Reminders.pendingCount(), 1);

    final end = DateTime.now().add(const Duration(minutes: 6));
    var delivered = <String>[];
    while (DateTime.now().isBefore(end)) {
      delivered = await Reminders.deliveredTitles();
      if (delivered.any((t) => t.contains('Fire test'))) break;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    // ignore: avoid_print
    print('REMINDER_FIRED $delivered after dose time ${soon.toIso8601String()} at ${DateTime.now().toIso8601String()}');
    expect(delivered.where((t) => t.contains('Fire test')), isNotEmpty);

    await db.deleteMember(member.id);
    await Reminders.reschedule();
    await closeDb();
    await storage.wipe();
  });
}
