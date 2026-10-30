import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';

import 'vault.dart';

/// Face ID / Touch ID / fingerprint, falling back to the device passcode.
abstract class Authenticator {
  Future<bool> isAvailable();
  Future<bool> authenticate(String reason);
}

class DeviceAuthenticator implements Authenticator {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }
}

/// Optional app lock. Data is encrypted either way; the lock stops someone
/// holding your unlocked phone from browsing the records.
class AppLock {
  static const _settingKey = 'medi_archive.app_lock';
  static Duration relockAfter = const Duration(minutes: 1);

  static late KeyStore _store;
  static Authenticator authenticator = DeviceAuthenticator();

  static bool enabled = false;

  /// Lock screen showing.
  static final locked = ValueNotifier<bool>(false);

  /// App is in the switcher / background: hide content from snapshots.
  static final obscured = ValueNotifier<bool>(false);
  static DateTime? _hiddenAt;

  static Future<void> init(KeyStore store) async {
    _store = store;
    enabled = await store.read(_settingKey) == '1';
    locked.value = enabled;
    obscured.value = false;
  }

  /// Turning the lock on or off requires authenticating first.
  static Future<bool> setEnabled(bool value) async {
    if (value && !await authenticator.isAvailable()) return false;
    if (!await authenticator.authenticate(value ? 'Turn on app lock' : 'Turn off app lock')) return false;
    enabled = value;
    await _store.write(_settingKey, value ? '1' : '0');
    return true;
  }

  static Future<bool> unlock() async {
    final ok = await authenticator.authenticate('Unlock your family health records');
    if (ok) locked.value = false;
    return ok;
  }

  static void onHidden() {
    if (!enabled) return;
    _hiddenAt ??= DateTime.now();
    obscured.value = true;
  }

  static void onVisible() {
    final hiddenAt = _hiddenAt;
    _hiddenAt = null;
    obscured.value = false;
    if (enabled && hiddenAt != null && DateTime.now().difference(hiddenAt) >= relockAfter) locked.value = true;
  }
}

/// Covers the app with the lock screen (keeping navigation state underneath).
class LockGate extends StatelessWidget {
  const LockGate({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([AppLock.locked, AppLock.obscured]),
    builder: (context, _) {
      final cover = AppLock.locked.value || AppLock.obscured.value;
      return Stack(children: [
        ExcludeSemantics(excluding: cover, child: TickerMode(enabled: !cover, child: child)),
        if (cover) Positioned.fill(child: _LockScreen(showButton: AppLock.locked.value)),
      ]);
    },
  );
}

class _LockScreen extends StatefulWidget {
  const _LockScreen({required this.showButton});
  final bool showButton;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> {
  bool _busy = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.showButton) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void didUpdateWidget(_LockScreen old) {
    super.didUpdateWidget(old);
    // The app-switcher cover became the lock screen: prompt straight away.
    if (widget.showButton && !old.showButton) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await AppLock.unlock();
    if (mounted) {
      setState(() {
        _busy = false;
        _failed = !ok;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.lock_rounded, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Family Health is locked', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
              if (widget.showButton) ...[
                const SizedBox(height: 8),
                Text(
                  _failed ? "Couldn't verify it's you. Try again." : 'Your records are encrypted on this device.',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _unlock,
                  icon: const Icon(Icons.fingerprint_rounded),
                  label: const Text('Unlock'),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
