import 'dart:io';

import 'package:flutter/material.dart';

import 'bootstrap.dart';
import 'screens/home_screen.dart';
import 'security/app_lock.dart';
import 'security/vault.dart';
import 'services/reminders.dart';
import 'theme.dart';

const _demo = bool.fromEnvironment('DEMO');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await start();
}

/// Opens the encrypted stores and shows the app, or an explanation if the
/// encryption key can't be read.
Future<void> start() async {
  try {
    // DEMO=true: sample family in separate storage.
    await bootstrap(config: _demo ? StorageConfig.demo : StorageConfig.real, seedDemoData: _demo);
  } catch (e) {
    runApp(StartupErrorApp(error: e));
    return;
  }
  runApp(const FamilyHealthApp());
  // Not awaited: reminders must never hold up the first frame.
  Reminders.init();
}

class FamilyHealthApp extends StatefulWidget {
  const FamilyHealthApp({super.key});

  @override
  State<FamilyHealthApp> createState() => _FamilyHealthAppState();
}

class _FamilyHealthAppState extends State<FamilyHealthApp> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    final mobile = Platform.isIOS || Platform.isAndroid;
    _lifecycle = AppLifecycleListener(
      // Phones snapshot the app for the switcher while inactive; desktops go
      // inactive whenever another window has focus, so only cover when hidden.
      onInactive: mobile ? AppLock.onHidden : null,
      onHide: AppLock.onHidden,
      onShow: AppLock.onVisible,
      onResume: () {
        AppLock.onVisible();
        // Refill the reminder window whenever the app comes back.
        Reminders.reschedule();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Family Health',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      builder: (context, child) => LockGate(child: child!),
      home: const HomeScreen(),
    );
  }
}

class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final locked = error is VaultLockedException;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.lock_outline_rounded, size: 56, color: Theme.of(context).colorScheme.error),
                  const SizedBox(height: 16),
                  Text(locked ? "Can't unlock your records" : 'Something went wrong while opening your records',
                      style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  Text(
                    locked
                        ? 'Your records are encrypted, and the key stored in this device\'s secure keychain could not be read. '
                              'Nothing has been deleted. Make sure the device is unlocked and try again. '
                              'If this device was restored or reset, import your latest backup instead.'
                        : '$error',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(onPressed: start, icon: const Icon(Icons.refresh_rounded), label: const Text('Try again')),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
