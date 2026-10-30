import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/database.dart';
import '../data/models.dart';

/// Local (on-device) medication reminders.
///
/// iOS allows only 64 pending notifications per app, so instead of scheduling a
/// whole course up front we keep a rolling window of the next [_maxPending]
/// untaken doses and refresh it whenever the app opens or data changes. A course
/// therefore keeps reminding until its last day, as long as the app is opened
/// at least once every couple of weeks.
class Reminders {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _maxPending = 60;
  static const _maxFollowUps = 3;
  static const _followUpIdBase = 1000;
  static const _horizon = Duration(days: 14);
  static bool _ready = false;

  static Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      final local = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(local.identifier));
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _ready = true;
      AppDb.instance.revision.addListener(_debouncedReschedule);
      await reschedule();
    } catch (e) {
      debugPrint('Reminders unavailable: $e');
    }
  }

  /// Asks for notification permission. Call when the user turns a reminder on.
  static Future<bool> requestPermission() async {
    if (!_ready) return false;
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, sound: true, badge: true) ??
          false;
    }
    if (Platform.isMacOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
              ?.requestPermissions(alert: true, sound: true, badge: true) ??
          false;
    }
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final granted = await android?.requestNotificationsPermission() ?? false;
      // Exact alarms make reminders arrive on time instead of "within a few minutes".
      if (granted && !(await android?.canScheduleExactNotifications() ?? true)) {
        await android?.requestExactAlarmsPermission();
      }
      return granted;
    }
    return false;
  }

  /// Reminders currently scheduled with the OS.
  static Future<int> pendingCount() async => (await _plugin.pendingNotificationRequests()).length;

  /// Reminders delivered and still showing. Test support.
  @visibleForTesting
  static Future<List<String>> deliveredTitles() async =>
      (await _plugin.getActiveNotifications()).map((n) => n.title ?? '').toList();

  /// Apple's silent "provisional" permission, so tests need no system prompt.
  @visibleForTesting
  static Future<void> grantProvisionalForTest() async {
    await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
      provisional: true,
      alert: true,
      sound: true,
    );
    await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
      provisional: true,
      alert: true,
      sound: true,
    );
  }

  static int _pendingRun = 0;
  static void _debouncedReschedule() {
    final run = ++_pendingRun;
    Future.delayed(const Duration(milliseconds: 400), () {
      if (run == _pendingRun) reschedule().catchError((Object e) => debugPrint('Reminder refresh failed: $e'));
    });
  }

  static Future<void>? _running;
  static bool _runAgain = false;

  /// Brings the OS schedule in line with the records. Runs one at a time: a
  /// request arriving mid-run triggers one more pass with the latest data.
  static Future<void> reschedule() async {
    if (!_ready) return;
    if (_running != null) {
      _runAgain = true;
      return _running;
    }
    _running = () async {
      do {
        _runAgain = false;
        await _schedule();
      } while (_runAgain);
    }();
    try {
      await _running;
    } finally {
      _running = null;
    }
  }

  static Future<void> _schedule() async {
    final db = AppDb.instance;
    final now = DateTime.now();
    final members = {for (final m in await db.members()) m.id: m};
    final meds = (await db.medications()).where((m) => m.reminders && !m.isFinishedOn(now));
    final taken = await db.takenDoses();

    final upcoming = <(DateTime, Medication)>[
      for (final m in meds)
        for (final slot in m.slotsBetween(now, now.add(_horizon)))
          if (!(taken[m.id]?.contains(DoseLog.slotKey(slot)) ?? false)) (slot, m),
    ]..sort((a, b) => a.$1.compareTo(b.$1));

    var exact = false;
    if (Platform.isAndroid) {
      exact =
          await _plugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
              ?.canScheduleExactNotifications() ??
          false;
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'medication',
        'Medication reminders',
        channelDescription: 'Reminders to take scheduled medicines',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.reminder,
      ),
      iOS: DarwinNotificationDetails(),
      macOS: DarwinNotificationDetails(),
    );

    // Same id replaces, so the schedule is never empty while this runs. Anything
    // not scheduled in this pass is removed at the end.
    final wanted = <int>{};

    // Follow-ups are few, so they fit beside the dose window under iOS's limit of 64.
    final followUps = await db.upcomingFollowUps();
    for (final (i, r) in followUps.take(_maxFollowUps).indexed) {
      final f = r.followUp!;
      var at = DateTime(f.year, f.month, f.day - 1, 9);
      if (at.isBefore(now)) at = DateTime(f.year, f.month, f.day, 9);
      if (at.isBefore(now)) continue;
      final doctor = r.doctorId == null ? null : await db.doctor(r.doctorId!);
      wanted.add(_followUpIdBase + i);
      await _plugin.zonedSchedule(
        id: _followUpIdBase + i,
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: details,
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        title: 'Follow-up ${at.day == f.day ? 'today' : 'tomorrow'}',
        body: [?members[r.memberId]?.name, r.title, ?doctor?.name].join(' · '),
        payload: r.id,
      );
    }

    for (final (i, (slot, m)) in upcoming.take(_maxPending).indexed) {
      final who = members[m.memberId]?.name ?? '';
      final course = m.days == null ? '' : ' · day ${m.dayNumber(slot)} of ${m.days}';
      wanted.add(i);
      await _plugin.zonedSchedule(
        id: i,
        scheduledDate: tz.TZDateTime.from(slot, tz.local),
        notificationDetails: details,
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        title: '💊 ${m.name}${m.dose == null ? '' : ' — ${m.dose}'}',
        body: [if (who.isNotEmpty) 'For $who', ?m.instructions].join(' · ') + course,
        payload: m.id,
      );
    }

    for (final pending in await _plugin.pendingNotificationRequests()) {
      if (!wanted.contains(pending.id)) await _plugin.cancel(id: pending.id);
    }
  }
}
