import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'auth_store.dart';
import 'cloud_sync.dart';
import 'login_screen.dart';
import 'player_hub.dart';
import 'ui.dart';

/// The top of the settings screen: the profile card with the logout button,
/// the cloud saving switch, and the change password fields.
class AccountSection extends StatelessWidget {
  const AccountSection({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _ProfileCard(),
        // Google accounts have no password here, so nothing is shown for them.
        if (auth.isSignedIn && auth.hasPassword) const _PasswordCard(),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  const _Card({required this.icon, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassContainer(
        borderRadius: 16,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: accent),
                const SizedBox(width: 8),
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  const _PillButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final base = danger
        ? Colors.redAccent.shade100
        : Theme.of(context).colorScheme.primary;
    final enabled = onTap != null;
    final color = enabled ? base : Colors.white24;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: color.withValues(alpha: enabled ? 0.1 : 0.03),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard();

  Future<void> _logout(BuildContext context) async {
    final auth = context.read<AuthStore>();
    final guest = auth.isGuest;
    final ok = await confirmDelete(
      context,
      title: guest ? 'Leave guest mode?' : 'Log out?',
      message: guest
          ? 'You will go back to the login screen. Your downloaded songs stay on this phone.'
          : 'You will need to sign in again to use your cloud saves. Your downloaded songs stay on this phone.',
      confirmLabel: guest ? 'Continue' : 'Log out',
    );
    if (!ok || !context.mounted) return;
    try {
      await context.read<PlayerHub>().close();
    } catch (_) {}
    await auth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthStore>();
    final cloud = context.watch<CloudSyncStore>();
    final accent = Theme.of(context).colorScheme.primary;
    final p = auth.profile;
    final guest = auth.isGuest;

    final String name = guest
        ? 'Guest'
        : ((p?.fullName.isNotEmpty ?? false)
              ? p!.fullName
              : (p?.email ?? 'Account'));

    final String syncText;
    if (guest) {
      syncText = 'Cloud saves need an account. Sign in to use them.';
    } else if (!auth.cloudSaving) {
      syncText = 'Off. New downloads stay on this phone only.';
    } else if (cloud.pendingCount > 0) {
      syncText = cloud.online
          ? 'Syncing ${cloud.pendingCount} song${cloud.pendingCount == 1 ? '' : 's'}...'
          : '${cloud.pendingCount} waiting for internet. They save by themselves when you are back online.';
    } else if (cloud.lastSynced == null) {
      syncText = 'Waiting for the first sync...';
    } else {
      syncText =
          'Cloud Sync Completed | Last Synced: ${_formatSynced(cloud.lastSynced!)}';
    }

    return _Card(
      icon: Icons.account_circle_rounded,
      title: 'Profile',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              guest
                  ? Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                      child: const Icon(
                        Icons.person_outline_rounded,
                        color: Colors.white54,
                      ),
                    )
                  : AccountAvatar(profile: p, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (guest && auth.guestId != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Guest ID: ${auth.guestId!.substring(0, 8)}',
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    if (!guest && (p?.email.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 2),
                      Text(
                        p!.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _PillButton(
                icon: guest ? Icons.login_rounded : Icons.logout_rounded,
                label: guest ? 'Sign in' : 'Log out',
                danger: !guest,
                onTap: () => _logout(context),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.cloud_sync_rounded,
                size: 20,
                color: guest ? Colors.white24 : accent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Cloud saving',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      syncText,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: !guest && auth.cloudSaving,
                  activeThumbColor: accent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: guest ? null : auth.setCloudSaving,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                Icons.cloud_download_rounded,
                size: 20,
                color: guest ? Colors.white24 : accent,
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Auto-Download Songs from Cloud',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'When the app starts, download every cloud song that is not on this device.',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Transform.scale(
                scale: 0.85,
                child: Switch(
                  value: !guest && auth.autoDownloadCloud,
                  activeThumbColor: accent,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: guest ? null : auth.setAutoDownloadCloud,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "16 Dec 2022 5:55 AM"
String _formatSynced(DateTime t) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final d = t.toLocal();
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '${d.day} ${months[d.month - 1]} ${d.year} $h12:$mm $ampm';
}

class _PasswordCard extends StatefulWidget {
  const _PasswordCard();

  @override
  State<_PasswordCard> createState() => _PasswordCardState();
}

class _PasswordCardState extends State<_PasswordCard> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label) {
    final accent = Theme.of(context).colorScheme.primary;
    OutlineInputBorder border(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: c, width: w),
    );
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54, fontSize: 13),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.05),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      enabledBorder: border(Colors.white.withValues(alpha: 0.10)),
      focusedBorder: border(accent, 1.5),
      errorBorder: border(Colors.redAccent.shade200),
      focusedErrorBorder: border(Colors.redAccent.shade200, 1.5),
      errorStyle: TextStyle(color: Colors.redAccent.shade100, fontSize: 11.5),
    );
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final auth = context.read<AuthStore>();
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await auth.changePassword(current: _current.text, next: _next.text);
      _current.clear();
      _next.clear();
      _confirm.clear();
      if (mounted) setState(() => _ok = 'Your password was changed.');
      Notch.show('Password updated', icon: Icons.lock_reset_rounded);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: Colors.white, fontSize: 13.5);
    final toggle = IconButton(
      icon: Icon(
        _show ? Icons.visibility_off_rounded : Icons.visibility_rounded,
        size: 17,
        color: Colors.white38,
      ),
      onPressed: () => setState(() => _show = !_show),
    );
    return _Card(
      icon: Icons.lock_outline_rounded,
      title: 'Change password',
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _current,
              obscureText: !_show,
              style: style,
              decoration: _dec('Current password').copyWith(suffixIcon: toggle),
              validator: (v) =>
                  (v ?? '').isEmpty ? 'Enter your current password' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _next,
              obscureText: !_show,
              style: style,
              decoration: _dec('New password'),
              validator: (v) {
                final s = v ?? '';
                if (s.length < 6) return 'Use at least 6 characters';
                if (s == _current.text) return 'Choose a different password';
                return null;
              },
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _confirm,
              obscureText: !_show,
              style: style,
              onFieldSubmitted: (_) => _busy ? null : _submit(),
              decoration: _dec('Confirm new password'),
              validator: (v) =>
                  v == _next.text ? null : 'Passwords do not match',
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(
                  color: Colors.redAccent.shade100,
                  fontSize: 12.5,
                ),
              ),
            ],
            if (_ok != null) ...[
              const SizedBox(height: 10),
              Text(
                _ok!,
                style: TextStyle(
                  color: Colors.greenAccent.shade200,
                  fontSize: 12.5,
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: _PillButton(
                icon: _busy ? Icons.hourglass_top_rounded : Icons.check_rounded,
                label: _busy ? 'Updating...' : 'Update password',
                onTap: _busy ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
