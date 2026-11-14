import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth_config.dart';
import 'auth_store.dart';
import 'biometric_lock.dart';
import 'countries.dart';
import 'ui.dart';

/// Decides what to show: the login screen, the "complete your profile" step,
/// or the app itself (for accounts and for guests).
class AuthGate extends StatelessWidget {
  final Widget child;
  const AuthGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    switch (auth.status) {
      case AuthStatus.loading:
        return const Scaffold(
          backgroundColor: AppColors.background,
          body: Center(child: CircularProgressIndicator()),
        );
      case AuthStatus.signedOut:
        return const LoginScreen();
      case AuthStatus.guest:
        return child;
      case AuthStatus.signedIn:
        final p = auth.profile;
        if (p != null && !p.complete) return const CompleteProfileScreen();
        // Face ID: the app opens only after the phone confirms the owner.
        if (context.watch<BiometricLock>().locked) return const LockScreen();
        return FaceIdPromptHost(child: child);
    }
  }
}

/// The prompt shown to a blacklisted account.
Future<void> showAccountDisabledDialog(BuildContext context) {
  final danger = Colors.redAccent.shade200;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: GlassContainer(
          borderRadius: 20,
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: danger.withValues(alpha: 0.15),
                    ),
                    child: Icon(Icons.block_rounded, color: danger, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Account disabled',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Your account has been disabled for violating the Terms & '
                'Conditions of $kCompanyName. Contact $kCompanyName for assistance.',
                style: TextStyle(
                  color: Colors.white70,
                  height: 1.45,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
              const SelectableText(
                kCompanySite,
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('OK'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

InputDecoration _decoration(
  BuildContext context,
  String label, {
  IconData? icon,
  Widget? suffix,
}) {
  final accent = Theme.of(context).colorScheme.primary;
  OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: c, width: w),
  );
  return InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: Colors.white54, fontSize: 13.5),
    prefixIcon: icon == null
        ? null
        : Icon(icon, size: 18, color: Colors.white38),
    suffixIcon: suffix,
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.05),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: border(Colors.white.withValues(alpha: 0.10)),
    focusedBorder: border(accent, 1.5),
    errorBorder: border(Colors.redAccent.shade200),
    focusedErrorBorder: border(Colors.redAccent.shade200, 1.5),
    errorStyle: TextStyle(color: Colors.redAccent.shade100, fontSize: 11.5),
  );
}

const TextStyle _fieldText = TextStyle(color: Colors.white, fontSize: 14);

final RegExp _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

/// Opens the searchable list of countries.
Future<Country?> showCountryPicker(BuildContext context, Country current) {
  return showDialog<Country>(
    context: context,
    builder: (_) => _CountryDialog(current: current),
  );
}

class _CountryDialog extends StatefulWidget {
  final Country current;
  const _CountryDialog({required this.current});

  @override
  State<_CountryDialog> createState() => _CountryDialogState();
}

class _CountryDialogState extends State<_CountryDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final q = _q.trim().toLowerCase().replaceFirst('+', '');
    final list = q.isEmpty
        ? kCountries
        : kCountries
              .where(
                (c) =>
                    c.name.toLowerCase().contains(q) ||
                    c.dial.startsWith(q) ||
                    c.iso.toLowerCase() == q,
              )
              .toList();
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 520),
        child: GlassContainer(
          borderRadius: 20,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                autofocus: true,
                style: _fieldText,
                decoration: _decoration(
                  context,
                  'Search country or code',
                  icon: Icons.search_rounded,
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final c = list[i];
                    final sel = c == widget.current;
                    return ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      onTap: () => Navigator.pop(context, c),
                      selected: sel,
                      selectedColor: accent,
                      title: Text(
                        c.name,
                        style: TextStyle(
                          color: sel ? accent : Colors.white,
                          fontSize: 13.5,
                        ),
                      ),
                      trailing: Text(
                        c.label,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "+370 ▾" button that opens the country list.
class CountryCodeButton extends StatelessWidget {
  final Country country;
  final ValueChanged<Country> onChanged;
  const CountryCodeButton({
    super.key,
    required this.country,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await showCountryPicker(context, country);
        if (picked != null) onChanged(picked);
      },
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Colors.white.withValues(alpha: 0.05),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              country.iso,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(width: 6),
            Text(country.label, style: _fieldText),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down_rounded, color: Colors.white54),
          ],
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  final double size;
  const _Logo({this.size = 76});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: accent.withValues(alpha: 0.4), blurRadius: 26),
        ],
      ),
      child: ClipOval(
        child: Image.asset(
          'assets/logo.png',
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) =>
              Icon(Icons.music_note_rounded, size: size * 0.6, color: accent),
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final bool good;
  const _ErrorBox(this.message, {this.good = false});

  @override
  Widget build(BuildContext context) {
    final color = good
        ? Colors.greenAccent.shade200
        : Colors.redAccent.shade200;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            good
                ? Icons.check_circle_outline_rounded
                : Icons.error_outline_rounded,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: color, fontSize: 12.5, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

enum _Mode { signIn, signUp }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  _Mode _mode = _Mode.signIn;
  Country _country = countryByIso('LT');
  bool _busy = false;
  bool _googleBusy = false;
  bool _showPassword = false;
  bool _dialogOpen = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    for (final c in [_first, _last, _phone, _email, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // An account that was disabled while the app was open (or at start-up)
    // lands here: tell the person why.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _dialogOpen) return;
      if (context.read<AuthStore>().takeBlockedNotice()) {
        await _showDisabled();
      }
    });
  }

  Future<void> _showDisabled() async {
    _dialogOpen = true;
    await showAccountDisabledDialog(context);
    _dialogOpen = false;
  }

  void _setMode(_Mode m) {
    setState(() {
      _mode = m;
      _error = null;
      _info = null;
    });
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      await job();
    } on AccountDisabledException {
      if (mounted) await _showDisabled();
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      debugPrint('[PalmTunes] Login error -> $e');
      if (mounted)
        setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthStore>();
    await _run(() {
      if (_mode == _Mode.signIn) {
        return auth.signInWithEmail(_email.text, _password.text);
      }
      return auth.signUp(
        firstName: _first.text,
        lastName: _last.text,
        countryIso: _country.iso,
        dial: _country.dial,
        phone: normalizePhone(_country, _phone.text),
        email: _email.text,
        password: _password.text,
      );
    });
  }

  Future<void> _google() async {
    final auth = context.read<AuthStore>();
    setState(() => _googleBusy = true);
    await _run(auth.signInWithGoogle);
    if (mounted) setState(() => _googleBusy = false);
  }

  Future<void> _forgot() async {
    final email = _email.text.trim();
    if (!_emailRe.hasMatch(email)) {
      setState(() {
        _info = null;
        _error = 'Type your email above first, then tap "Forgot password?".';
      });
      return;
    }
    final auth = context.read<AuthStore>();
    await _run(() async {
      await auth.sendPasswordReset(email);
      if (mounted) setState(() => _info = 'A reset link was sent to $email.');
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watching makes didChangeDependencies run when the store changes.
    final auth = context.watch<AuthStore>();
    final accent = Theme.of(context).colorScheme.primary;
    final signUp = _mode == _Mode.signUp;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: GlassContainer(
                borderRadius: 24,
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                child: Form(
                  key: _form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: _Logo()),
                      const SizedBox(height: 14),
                      const Text(
                        'Palm Tunes',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 0.6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        signUp
                            ? 'Create your account'
                            : 'Sign in to keep your songs in the cloud',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 18),
                      _ModeSwitch(
                        mode: _mode,
                        onChanged: _busy ? null : _setMode,
                      ),
                      const SizedBox(height: 16),
                      if (!auth.firebaseOk)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 12),
                          child: _ErrorBox(
                            'Cloud services could not start, so signing in is unavailable. You can still use the app as a guest.',
                          ),
                        ),
                      if (signUp) ...[
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _first,
                                style: _fieldText,
                                textInputAction: TextInputAction.next,
                                textCapitalization: TextCapitalization.words,
                                decoration: _decoration(context, 'First name'),
                                validator: (v) => (v ?? '').trim().isEmpty
                                    ? 'Enter your first name'
                                    : null,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _last,
                                style: _fieldText,
                                textInputAction: TextInputAction.next,
                                textCapitalization: TextCapitalization.words,
                                decoration: _decoration(context, 'Last name'),
                                validator: (v) => (v ?? '').trim().isEmpty
                                    ? 'Enter your last name'
                                    : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CountryCodeButton(
                              country: _country,
                              onChanged: (c) => setState(() => _country = c),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: TextFormField(
                                controller: _phone,
                                style: _fieldText,
                                keyboardType: TextInputType.phone,
                                textInputAction: TextInputAction.next,
                                decoration: _decoration(
                                  context,
                                  'Phone number',
                                ),
                                validator: (v) =>
                                    validatePhone(_country, v ?? ''),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: _email,
                        style: _fieldText,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
                        decoration: _decoration(
                          context,
                          'Email',
                          icon: Icons.mail_outline_rounded,
                        ),
                        validator: (v) => _emailRe.hasMatch((v ?? '').trim())
                            ? null
                            : 'Enter a valid email address',
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _password,
                        style: _fieldText,
                        obscureText: !_showPassword,
                        textInputAction: signUp
                            ? TextInputAction.next
                            : TextInputAction.done,
                        onFieldSubmitted: (_) {
                          if (!signUp && !_busy) _submit();
                        },
                        decoration: _decoration(
                          context,
                          'Password',
                          icon: Icons.lock_outline_rounded,
                          suffix: IconButton(
                            icon: Icon(
                              _showPassword
                                  ? Icons.visibility_off_rounded
                                  : Icons.visibility_rounded,
                              size: 18,
                              color: Colors.white38,
                            ),
                            onPressed: () =>
                                setState(() => _showPassword = !_showPassword),
                          ),
                        ),
                        validator: (v) {
                          final s = v ?? '';
                          if (s.isEmpty) return 'Enter your password';
                          if (signUp && s.length < 6) {
                            return 'Use at least 6 characters';
                          }
                          return null;
                        },
                      ),
                      if (signUp) ...[
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _confirm,
                          style: _fieldText,
                          obscureText: !_showPassword,
                          textInputAction: TextInputAction.done,
                          onFieldSubmitted: (_) {
                            if (!_busy) _submit();
                          },
                          decoration: _decoration(
                            context,
                            'Confirm password',
                            icon: Icons.lock_outline_rounded,
                          ),
                          validator: (v) => v == _password.text
                              ? null
                              : 'Passwords do not match',
                        ),
                      ] else
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _busy ? null : _forgot,
                            child: const Text('Forgot password?'),
                          ),
                        ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        _ErrorBox(_error!),
                      ],
                      if (_info != null) ...[
                        const SizedBox(height: 8),
                        _ErrorBox(_info!, good: true),
                      ],
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 46,
                        child: FilledButton(
                          onPressed: (_busy || !auth.firebaseOk)
                              ? null
                              : _submit,
                          child: _busy && !_googleBusy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(signUp ? 'Create account' : 'Sign in'),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: Divider(
                              color: Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 10),
                            child: Text(
                              'or',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Divider(
                              color: Colors.white.withValues(alpha: 0.1),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        height: 46,
                        child: OutlinedButton(
                          onPressed: (_busy || !auth.firebaseOk)
                              ? null
                              : _google,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: BorderSide(
                              color: Colors.white.withValues(alpha: 0.2),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _googleBusy
                              ? Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    const Text('Signing in...'),
                                  ],
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Container(
                                      width: 22,
                                      height: 22,
                                      alignment: Alignment.center,
                                      decoration: const BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.white,
                                      ),
                                      child: const Text(
                                        'G',
                                        style: TextStyle(
                                          color: Color(0xFF4285F4),
                                          fontWeight: FontWeight.w900,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    const Text('Continue with Google'),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run(auth.continueAsGuest),
                        child: Text(
                          'Continue as guest',
                          style: TextStyle(color: accent),
                        ),
                      ),
                      const Text(
                        'Guests keep everything on this phone. Cloud saves need an account.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 11.5),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeSwitch extends StatelessWidget {
  final _Mode mode;
  final ValueChanged<_Mode>? onChanged;
  const _ModeSwitch({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    Widget tab(String label, _Mode m) {
      final sel = mode == m;
      return Expanded(
        child: GestureDetector(
          onTap: onChanged == null ? null : () => onChanged!(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: sel ? accent.withValues(alpha: 0.18) : Colors.transparent,
              border: Border.all(
                color: sel ? accent.withValues(alpha: 0.6) : Colors.transparent,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: sel ? accent : Colors.white60,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.05),
      ),
      child: Row(
        children: [
          tab('Sign in', _Mode.signIn),
          tab('Create account', _Mode.signUp),
        ],
      ),
    );
  }
}

/// Shown after the first Google sign-in (and for any account that has no
/// name or phone yet): asks for what Google does not give.
class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _first;
  late final TextEditingController _last;
  final _phone = TextEditingController();
  late Country _country;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = context.read<AuthStore>().profile;
    _first = TextEditingController(text: p?.firstName ?? '');
    _last = TextEditingController(text: p?.lastName ?? '');
    _country = countryByIso(p?.countryIso);
    if ((p?.phone ?? '').isNotEmpty) _phone.text = p!.phone;
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthStore>();
    final old = auth.profile;
    setState(() => _busy = true);
    await auth.saveProfile(
      UserProfile(
        firstName: _first.text.trim(),
        lastName: _last.text.trim(),
        countryIso: _country.iso,
        dial: _country.dial,
        phone: normalizePhone(_country, _phone.text),
        email: old?.email ?? '',
        photoUrl: old?.photoUrl,
      ),
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final p = auth.profile;
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: GlassContainer(
                borderRadius: 24,
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                child: Form(
                  key: _form,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(child: AccountAvatar(profile: p, size: 72)),
                      const SizedBox(height: 14),
                      const Text(
                        'Complete your profile',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        p?.email ?? '',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _first,
                              style: _fieldText,
                              textCapitalization: TextCapitalization.words,
                              decoration: _decoration(context, 'First name'),
                              validator: (v) => (v ?? '').trim().isEmpty
                                  ? 'Enter your first name'
                                  : null,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: _last,
                              style: _fieldText,
                              textCapitalization: TextCapitalization.words,
                              decoration: _decoration(context, 'Last name'),
                              validator: (v) => (v ?? '').trim().isEmpty
                                  ? 'Enter your last name'
                                  : null,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CountryCodeButton(
                            country: _country,
                            onChanged: (c) => setState(() => _country = c),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: _phone,
                              style: _fieldText,
                              keyboardType: TextInputType.phone,
                              onFieldSubmitted: (_) => _busy ? null : _save(),
                              decoration: _decoration(context, 'Phone number'),
                              validator: (v) =>
                                  validatePhone(_country, v ?? ''),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 46,
                        child: FilledButton(
                          onPressed: _busy ? null : _save,
                          child: _busy
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Save and continue'),
                        ),
                      ),
                      const SizedBox(height: 6),
                      TextButton(
                        onPressed: _busy ? null : auth.signOut,
                        child: const Text('Use a different account'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture from the Google account, or the person's initials.
class AccountAvatar extends StatelessWidget {
  final UserProfile? profile;
  final double size;
  const AccountAvatar({super.key, required this.profile, this.size = 56});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final initials = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accent.withValues(alpha: 0.18),
        border: Border.all(color: accent.withValues(alpha: 0.5)),
      ),
      child: Text(
        profile?.initials ?? '?',
        style: TextStyle(
          color: accent,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.36,
        ),
      ),
    );
    final url = profile?.photoUrl;
    if (url == null || url.isEmpty) return initials;
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stack) => initials,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : initials,
      ),
    );
  }
}
