import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_store.dart';
import 'ui.dart';

/// Face ID (or Touch ID / fingerprint / the phone's passcode) for opening the
/// app. It only protects accounts that are signed in: the account stays signed
/// in on the phone, and every time the app is opened from scratch the phone is
/// asked to confirm it is really the owner.
class BiometricLock extends ChangeNotifier {
  static const String _kEnabled = 'pt_biometric_lock';
  static const String _kAsked = 'pt_biometric_asked';

  final LocalAuthentication _auth = LocalAuthentication();
  SharedPreferences? _prefs;
  AuthStore? _account;

  bool _enabled = false;
  bool _asked = false;
  bool _locked = false;
  bool _available = false;
  bool _wasSignedIn = false;
  bool _busy = false;
  String _label = 'Face ID';

  /// The user turned the lock on in settings.
  bool get enabled => _enabled;

  /// The app is locked right now: show the lock screen.
  bool get locked =>
      _enabled && _locked && (_account?.isSignedIn ?? false);

  /// This phone can do it (it has Face ID, a fingerprint reader or a passcode).
  bool get available => _available;

  /// The "turn on Face ID?" question was already answered.
  bool get asked => _asked;

  /// "Face ID", "Touch ID", "Fingerprint"...
  String get label => _label;

  IconData get icon => _label == 'Face ID' || _label == 'Face unlock'
      ? Icons.face_unlock_rounded
      : Icons.fingerprint_rounded;

  Future<void> load(AuthStore account) async {
    _account = account;
    try {
      _prefs = await SharedPreferences.getInstance();
      _enabled = _prefs?.getBool(_kEnabled) ?? false;
      _asked = _prefs?.getBool(_kAsked) ?? false;
    } catch (_) {}
    await _checkAvailable();
    if (_enabled && !_available) {
      // The phone has no lock at all any more: do not lock the user out.
      _enabled = false;
      unawaited(_save());
    }
    // Opened from scratch: locked until the phone says it is the owner.
    _locked = _enabled;
    _wasSignedIn = account.isSignedIn;
    account.addListener(_onAccount);
  }

  Future<void> _checkAvailable() async {
    try {
      _available = await _auth.isDeviceSupported();
      final types = await _auth.getAvailableBiometrics();
      _label = _labelFor(types);
    } catch (_) {
      _available = false;
    }
  }

  String _labelFor(List<BiometricType> types) {
    final face = types.contains(BiometricType.face);
    final finger = types.contains(BiometricType.fingerprint);
    if (Platform.isIOS) {
      if (face) return 'Face ID';
      if (finger) return 'Touch ID';
      return 'Device passcode';
    }
    if (face && !finger) return 'Face unlock';
    if (finger && !face) return 'Fingerprint';
    if (face || finger || types.isNotEmpty) return 'Biometrics';
    return 'Screen lock';
  }

  void _onAccount() {
    final account = _account;
    if (account == null || account.status == AuthStatus.loading) return;
    final signedIn = account.isSignedIn;
    if (signedIn && !_wasSignedIn) {
      // Just typed the password (or used Google): no need to ask again now.
      _locked = false;
    }
    if (!signedIn && _wasSignedIn) {
      // Logged out: the next account starts fresh and gets asked again.
      _enabled = false;
      _asked = false;
      _locked = false;
      unawaited(_save());
      notifyListeners();
    }
    _wasSignedIn = signedIn;
  }

  Future<void> _save() async {
    try {
      await _prefs?.setBool(_kEnabled, _enabled);
      await _prefs?.setBool(_kAsked, _asked);
    } catch (_) {}
  }

  Future<bool> _confirm(String reason) async {
    if (_busy) return false;
    _busy = true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          // false: the phone's passcode works too if the face is not read.
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (e) {
      debugPrint('[PalmTunes] $_label failed -> $e');
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Asks the phone to confirm the owner and opens the app if it does.
  Future<bool> unlock() async {
    final ok = await _confirm('Unlock Palm Tunes');
    if (ok) {
      _locked = false;
      notifyListeners();
    }
    return ok;
  }

  /// Turns the lock on or off. Both need the phone to confirm first.
  Future<bool> setEnabled(bool value) async {
    if (value == _enabled) return true;
    if (value && !_available) return false;
    final ok = await _confirm(
      value ? 'Turn on $_label for Palm Tunes' : 'Turn off $_label for Palm Tunes',
    );
    if (!ok) return false;
    _enabled = value;
    _asked = true;
    _locked = false;
    await _save();
    notifyListeners();
    return true;
  }

  /// The "turn on Face ID?" question was answered with "Not now".
  Future<void> markAsked() async {
    _asked = true;
    await _save();
    notifyListeners();
  }

  @override
  void dispose() {
    _account?.removeListener(_onAccount);
    super.dispose();
  }
}

/// Shown instead of the app while it is locked. The phone's Face ID prompt
/// appears by itself; the button is there for trying again.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 350), _try);
    });
  }

  Future<void> _try() async {
    if (!mounted) return;
    setState(() => _failed = false);
    final ok = await context.read<BiometricLock>().unlock();
    if (!ok && mounted) setState(() => _failed = true);
  }

  @override
  Widget build(BuildContext context) {
    final lock = context.watch<BiometricLock>();
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipOval(
                  child: Image.asset(
                    'assets/logo.png',
                    width: 84,
                    height: 84,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stack) => Icon(
                      Icons.music_note_rounded,
                      size: 64,
                      color: accent,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Palm Tunes is locked',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _failed
                      ? '${lock.label} did not work. Try again.'
                      : 'Confirm it is you with ${lock.label}.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13.5),
                ),
                const SizedBox(height: 26),
                FilledButton.icon(
                  onPressed: _try,
                  icon: Icon(lock.icon),
                  label: Text('Unlock with ${lock.label}'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(220, 48),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => context.read<AuthStore>().signOut(),
                  child: const Text(
                    'Sign out instead',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps the app and, once, asks a signed-in user whether to use Face ID.
class FaceIdPromptHost extends StatefulWidget {
  final Widget child;
  const FaceIdPromptHost({super.key, required this.child});

  @override
  State<FaceIdPromptHost> createState() => _FaceIdPromptHostState();
}

class _FaceIdPromptHostState extends State<FaceIdPromptHost> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future<void>.delayed(const Duration(milliseconds: 700), _maybeAsk);
    });
  }

  Future<void> _maybeAsk() async {
    if (!mounted || _shown) return;
    final lock = context.read<BiometricLock>();
    final auth = context.read<AuthStore>();
    if (!auth.isSignedIn || !lock.available || lock.asked || lock.enabled) {
      return;
    }
    _shown = true;
    final accent = Theme.of(context).colorScheme.primary;
    final label = lock.label;
    final yes = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: GlassContainer(
            borderRadius: 20,
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: accent.withValues(alpha: 0.15),
                    ),
                    child: Icon(lock.icon, color: accent, size: 34),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Use $label?',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Open Palm Tunes with $label instead of signing in again. '
                  'You stay signed in, and you can change this any time in '
                  'Settings.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    height: 1.4,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text('Allow $label'),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text(
                    'Not now',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (yes == true) {
      final ok = await lock.setEnabled(true);
      if (!ok) await lock.markAsked();
    } else {
      await lock.markAsked();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
