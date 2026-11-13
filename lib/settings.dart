import 'dart:io' show Platform;
import 'dart:math';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account_settings.dart';
import 'downloads.dart';
import 'gesture_bridge.dart';
import 'legal_docs.dart';
import 'ui.dart';

const String hamTechUrl = 'https://ham-tech.netlify.app';

class SettingsStore extends ChangeNotifier {
  // Blue, green, red (the app's main theme), orange, yellow, pink, purple.
  static const List<Color> accentPresets = [
    Color(0xFFE11D48),
    Color(0xFF3B82F6),
    Color(0xFF22C55E),
    Color(0xFFF97316),
    Color(0xFFEAB308),
    Color(0xFFEC4899),
    Color(0xFFA855F7),
  ];

  static const List<int> autoMaximizeOptions = [0, 5, 10, 30, 60];
  static const List<int> crossfadeOptions = [5, 10, 15, 30];

  static const _kAccent = 'pt_accent';
  static const _kBlur = 'pt_glass_blur';
  static const _kSeek = 'pt_seek_seconds';
  static const _kHold = 'pt_hold_speed';
  static const _kAutoplay = 'pt_autoplay_next';
  static const _kPreferLocal = 'pt_prefer_downloaded';
  static const _kPip = 'pt_pip';
  static const _kAutoMax = 'pt_auto_maximize';
  static const _kCrossfade = 'pt_crossfade';
  static const _kCrossfadeSecs = 'pt_crossfade_seconds';

  static const Color _defaultAccent = Color(0xFFE11D48);
  static const double _defaultBlur = 18;
  static const int _defaultSeek = 10;
  static const double _defaultHold = 2.0;
  static const int _defaultAutoMax = 0;
  static const int _defaultCrossfadeSeconds = 10;
  static const bool _defaultCrossfade = true;

  Color _accent = _defaultAccent;
  double _glassBlur = _defaultBlur;
  int _seekSeconds = _defaultSeek;
  double _holdSpeed = _defaultHold;
  bool _autoplayNext = true;
  bool _preferDownloaded = true;
  bool _pip = true;
  int _autoMaximizeSeconds = _defaultAutoMax;
  bool _crossfade = _defaultCrossfade;
  int _crossfadeSeconds = _defaultCrossfadeSeconds;
  SharedPreferences? _prefs;

  Color get accentColor => _accent;
  double get glassBlur => _glassBlur;
  int get seekSeconds => _seekSeconds;
  double get holdSpeed => _holdSpeed;
  bool get autoplayNext => _autoplayNext;
  bool get preferDownloaded => _preferDownloaded;
  bool get pipEnabled => _pip;
  int get autoMaximizeSeconds => _autoMaximizeSeconds;
  bool get crossfadeEnabled => _crossfade;
  int get crossfadeSeconds => _crossfadeSeconds;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final p = _prefs!;
    final accent = p.getInt(_kAccent);
    if (accent != null) _accent = Color(accent);
    _glassBlur = p.getDouble(_kBlur) ?? _defaultBlur;
    _seekSeconds = p.getInt(_kSeek) ?? _defaultSeek;
    _holdSpeed = p.getDouble(_kHold) ?? _defaultHold;
    _autoplayNext = p.getBool(_kAutoplay) ?? true;
    _preferDownloaded = p.getBool(_kPreferLocal) ?? true;
    _pip = p.getBool(_kPip) ?? true;
    final autoMax = p.getInt(_kAutoMax) ?? _defaultAutoMax;
    _autoMaximizeSeconds = autoMaximizeOptions.contains(autoMax)
        ? autoMax
        : _defaultAutoMax;
    _crossfade = p.getBool(_kCrossfade) ?? _defaultCrossfade;
    final fade = p.getInt(_kCrossfadeSecs) ?? _defaultCrossfadeSeconds;
    _crossfadeSeconds = crossfadeOptions.contains(fade)
        ? fade
        : _defaultCrossfadeSeconds;
    notifyListeners();
  }

  void setAccent(Color c) {
    _accent = c;
    _prefs?.setInt(_kAccent, c.toARGB32());
    notifyListeners();
  }

  void setGlassBlur(double v) {
    _glassBlur = v;
    _prefs?.setDouble(_kBlur, v);
    notifyListeners();
  }

  void setSeekSeconds(int v) {
    _seekSeconds = v;
    _prefs?.setInt(_kSeek, v);
    notifyListeners();
  }

  void setHoldSpeed(double v) {
    _holdSpeed = v;
    _prefs?.setDouble(_kHold, v);
    notifyListeners();
  }

  void setAutoplayNext(bool v) {
    _autoplayNext = v;
    _prefs?.setBool(_kAutoplay, v);
    notifyListeners();
  }

  void setPip(bool v) {
    _pip = v;
    _prefs?.setBool(_kPip, v);
    notifyListeners();
  }

  void setPreferDownloaded(bool v) {
    _preferDownloaded = v;
    _prefs?.setBool(_kPreferLocal, v);
    notifyListeners();
  }

  void setAutoMaximizeSeconds(int v) {
    _autoMaximizeSeconds = v;
    _prefs?.setInt(_kAutoMax, v);
    notifyListeners();
  }

  void setCrossfade(bool v) {
    _crossfade = v;
    _prefs?.setBool(_kCrossfade, v);
    notifyListeners();
  }

  void setCrossfadeSeconds(int v) {
    if (!crossfadeOptions.contains(v)) return;
    _crossfadeSeconds = v;
    _prefs?.setInt(_kCrossfadeSecs, v);
    notifyListeners();
  }

  Future<void> resetDefaults() async {
    _accent = _defaultAccent;
    _glassBlur = _defaultBlur;
    _seekSeconds = _defaultSeek;
    _holdSpeed = _defaultHold;
    _autoplayNext = true;
    _preferDownloaded = true;
    _pip = true;
    _autoMaximizeSeconds = _defaultAutoMax;
    _crossfade = _defaultCrossfade;
    _crossfadeSeconds = _defaultCrossfadeSeconds;
    final p = _prefs;
    if (p != null) {
      await Future.wait([
        p.remove(_kAccent),
        p.remove(_kBlur),
        p.remove(_kSeek),
        p.remove(_kHold),
        p.remove(_kAutoplay),
        p.remove(_kPreferLocal),
        p.remove(_kPip),
        p.remove(_kAutoMax),
        p.remove(_kCrossfade),
        p.remove(_kCrossfadeSecs),
      ]);
    }
    notifyListeners();
  }
}

// ===========================================================================
// Screen
// ===========================================================================

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  Future<void> _pickColor(BuildContext context) async {
    final settings = context.read<SettingsStore>();
    var picked = settings.accentColor;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(24),
        child: GlassContainer(
          borderRadius: 20,
          opacity: 0.12,
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SingleChildScrollView(
                child: ColorPicker(
                  pickerColor: picked,
                  onColorChanged: (c) => picked = c,
                  enableAlpha: false,
                  labelTypes: const [],
                  pickerAreaHeightPercent: 0.7,
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Use color'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok == true) settings.setAccent(picked);
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>();
    final g = context.watch<GestureBridge>();
    final downloads = context.watch<DownloadsStore>();
    final accent = Theme.of(context).colorScheme.primary;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 170),
      children: [
        const Text(
          'Settings',
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 14),
        const AccountSection(),

        _Group(
          title: 'Camera gestures',
          icon: Icons.back_hand_rounded,
          children: [
            _SwitchRow(
              title: 'Control with hand gestures',
              subtitle: _gestureStatus(g),
              value: g.enabled,
              onChanged: g.setEnabled,
            ),
            _SwitchRow(
              title: 'Preview cam',
              subtitle:
                  'Show what the camera sees, with your hands drawn on it',
              value: g.previewing,
              onChanged: g.setPreview,
            ),
            _ChoiceRow<CameraLensDirection>(
              title: 'Camera',
              value: g.lens,
              options: const {
                CameraLensDirection.front: 'Front',
                CameraLensDirection.back: 'Back',
              },
              onChanged: g.setLens,
            ),
            _SwitchRow(
              title: 'Flip hands',
              subtitle: 'Turn on if the drawn hand moves the opposite way to yours',
              value: g.flipHands,
              onChanged: g.setFlipHands,
            ),
            _SwitchRow(
              title: 'Flip swipe direction',
              subtitle: 'Turn on if next and previous feel reversed',
              value: g.flipSwipe,
              onChanged: g.setFlipSwipe,
            ),
            const _GestureCheatSheet(),
          ],
        ),

        _Group(
          title: 'Playback',
          icon: Icons.play_circle_rounded,
          children: [
            _SwitchRow(
              title: 'Autoplay next',
              subtitle: 'Keep going when a song ends',
              value: s.autoplayNext,
              onChanged: s.setAutoplayNext,
            ),
            _SwitchRow(
              title: 'Crossfade',
              subtitle: 'Blend the end of a song into the next one',
              value: s.crossfadeEnabled,
              onChanged: s.setCrossfade,
            ),
            if (s.crossfadeEnabled)
              _ChoiceRow<int>(
                title: 'Crossfade length',
                value: s.crossfadeSeconds,
                options: {
                  for (final v in SettingsStore.crossfadeOptions) v: '${v}s',
                },
                onChanged: s.setCrossfadeSeconds,
              ),
            if (Platform.isIOS)
              _SwitchRow(
                title: 'Picture in Picture',
                subtitle:
                    'Keep the video in a small window when you leave the app. Loads the video a second time while the player is open',
                value: s.pipEnabled,
                onChanged: s.setPip,
              ),
            _SwitchRow(
              title: 'Prefer downloaded copy',
              subtitle:
                  'Play the saved file instead of streaming when you have it',
              value: s.preferDownloaded,
              onChanged: s.setPreferDownloaded,
            ),
            _ChoiceRow<int>(
              title: 'Double-tap skip',
              value: s.seekSeconds,
              options: const {5: '5s', 10: '10s', 15: '15s', 30: '30s'},
              onChanged: s.setSeekSeconds,
            ),
            _ChoiceRow<double>(
              title: 'Hold speed',
              value: s.holdSpeed,
              options: {1.5: '1.5x', 2.0: '2x', 3.0: '3x'},
              onChanged: s.setHoldSpeed,
            ),
          ],
        ),

        _Group(
          title: 'Appearance',
          icon: Icons.palette_rounded,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final c in SettingsStore.accentPresets)
                    GestureDetector(
                      onTap: () => s.setAccent(c),
                      child: Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: s.accentColor.toARGB32() == c.toARGB32()
                                ? Colors.white
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                        child: s.accentColor.toARGB32() == c.toARGB32()
                            ? const Icon(
                                Icons.check_rounded,
                                color: Colors.white,
                                size: 20,
                              )
                            : null,
                      ),
                    ),
                  GestureDetector(
                    onTap: () => _pickColor(context),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white38),
                      ),
                      child: const Icon(
                        Icons.colorize_rounded,
                        color: Colors.white70,
                        size: 19,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _SliderRow(
              title: 'Glass blur',
              value: s.glassBlur,
              min: 0,
              max: 30,
              label: s.glassBlur.round().toString(),
              onChanged: s.setGlassBlur,
            ),
          ],
        ),

        _Group(
          title: 'Storage',
          icon: Icons.sd_storage_rounded,
          children: [
            _InfoRow(
              title: 'Downloads',
              value:
                  '${downloadsLabel(downloads.videos.length)} · ${formatBytes(downloads.totalBytes)}',
            ),
          ],
        ),

        _Group(
          title: 'About',
          icon: Icons.info_rounded,
          children: [
            const _InfoRow(title: 'Palm Tunes', value: 'Version 1.0.0'),
            _HamTechRow(
              onTap: () => launchUrl(
                Uri.parse(hamTechUrl),
                mode: LaunchMode.externalApplication,
              ),
            ),
            _LinkRow(
              icon: Icons.privacy_tip_rounded,
              title: 'Privacy Policy',
              onTap: () => showLegalDocument(
                context,
                title: 'Privacy Policy',
                asset: 'assets/legal/privacy_policy.md',
              ),
            ),
            _LinkRow(
              icon: Icons.gavel_rounded,
              title: 'Legal',
              onTap: () => showLegalDocument(
                context,
                title: 'Legal',
                asset: 'assets/legal/legal_notice.md',
              ),
            ),
          ],
        ),

        const SizedBox(height: 4),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await confirmDelete(
              context,
              title: 'Reset settings?',
              message: 'Colors, playback and blur go back to their defaults. Your songs and downloads are not touched.',
              confirmLabel: 'Reset',
            );
            if (ok) await s.resetDefaults();
          },
          icon: const Icon(Icons.restart_alt_rounded),
          label: const Text('Reset to defaults'),
          style: OutlinedButton.styleFrom(
            foregroundColor: accent,
            side: BorderSide(color: accent.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ],
    );
  }

  static String _gestureStatus(GestureBridge g) {
    switch (g.status) {
      case GestureStatus.off:
        return 'Off';
      case GestureStatus.starting:
        return 'Starting the camera...';
      case GestureStatus.ready:
        return g.enabled
            ? (g.asleep
                  ? 'Asleep. Show two thumbs up to wake'
                  : 'On. Camera works while the app is open')
            : 'Off';
      case GestureStatus.noCamera:
        return 'No camera found';
      case GestureStatus.noPermission:
        return 'Camera permission is off. Allow it in system settings';
      case GestureStatus.unsupported:
        return 'Not supported on this device';
      case GestureStatus.crashed:
        return 'Stopped${g.lastError == null ? '' : ': ${g.lastError}'}';
    }
  }
}

class _Group extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _Group({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: GlassContainer(
        borderRadius: 20,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: accent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: Colors.white, fontSize: 14.5),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: Colors.white,
            activeTrackColor: accent,
          ),
        ],
      ),
    );
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  final String title;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  const _ChoiceRow({
    required this.title,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
            ),
          ),
          Wrap(
            spacing: 6,
            children: [
              for (final e in options.entries)
                GestureDetector(
                  onTap: () => onChanged(e.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      color: e.key == value
                          ? accent.withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.05),
                      border: Border.all(
                        color: e.key == value
                            ? accent.withValues(alpha: 0.6)
                            : Colors.white12,
                      ),
                    ),
                    child: Text(
                      e.value,
                      style: TextStyle(
                        color: e.key == value ? accent : Colors.white70,
                        fontWeight: FontWeight.w600,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SliderRow extends StatelessWidget {
  final String title;
  final double value;
  final double min;
  final double max;
  final String label;
  final ValueChanged<double> onChanged;
  const _SliderRow({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
            ),
          ),
          Expanded(
            flex: 5,
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 26,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String title;
  final String value;
  const _InfoRow({required this.title, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 9),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 14.5),
          ),
        ),
        Text(
          value,
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
      ],
    ),
  );
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(10),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: [
          Icon(icon, size: 19, color: Colors.white54),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: Colors.white30),
        ],
      ),
    ),
  );
}

class _GestureCheatSheet extends StatelessWidget {
  const _GestureCheatSheet();

  static const _rows = [
    (Icons.swipe_rounded, 'Point and swipe', 'Right = next, left = previous'),
    (Icons.back_hand_outlined, 'Peace sign', 'Pause'),
    (Icons.thumb_up_alt_rounded, 'Thumbs up', 'Play'),
    (
      Icons.rotate_right_rounded,
      'Turn a knob',
      'Pinch thumb with two fingers and twist for volume',
    ),
    (
      Icons.front_hand_rounded,
      'Palm, then fist',
      'Mute. Show a palm again to unmute',
    ),
    (
      Icons.bedtime_rounded,
      'Two thumbs up / two palms',
      'Put gestures to sleep / wake them',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: const Text(
          'Gesture guide',
          style: TextStyle(color: Colors.white, fontSize: 14.5),
        ),
        iconColor: Colors.white54,
        collapsedIconColor: Colors.white54,
        children: [
          for (final r in _rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(r.$1, size: 18, color: Colors.white54),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.$2,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          r.$3,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}


class _HamTechRow extends StatelessWidget {
  final VoidCallback onTap;
  const _HamTechRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const _LaserBadge(label: 'Ham-Tech'),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Built by Ham-Tech',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                ),
                SizedBox(height: 2),
                Text(
                  'ham-tech.netlify.app',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white54, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onTap,
            icon: Icon(Icons.open_in_new_rounded, color: accent, size: 20),
            tooltip: 'Visit site',
          ),
        ],
      ),
    );
  }
}

class _LaserBadge extends StatefulWidget {
  final String label;
  const _LaserBadge({required this.label});

  @override
  State<_LaserBadge> createState() => _LaserBadgeState();
}

class _LaserBadgeState extends State<_LaserBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return CustomPaint(
      foregroundPainter: _LaserPainter(progress: _ctrl, color: accent, radius: 11),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt_rounded, size: 16, color: accent),
            const SizedBox(width: 5),
            Text(
              widget.label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LaserPainter extends CustomPainter {
  final Animation<double> progress;
  final Color color;
  final double radius;

  _LaserPainter({required this.progress, required this.color, required this.radius})
    : super(repaint: progress);

  static const int _pieces = 28;
  static const double _tailFraction = 0.3;

  void _drawSegment(Canvas canvas, PathMetric metric, double start, double end, Paint paint) {
    final len = metric.length;
    final span = end - start;
    if (span <= 0) return;
    final s = ((start % len) + len) % len;
    final e = s + span;
    if (e <= len) {
      canvas.drawPath(metric.extractPath(s, e), paint);
    } else {
      canvas.drawPath(metric.extractPath(s, len), paint);
      canvas.drawPath(metric.extractPath(0, e - len), paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(0.75),
      Radius.circular(radius),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color.withValues(alpha: 0.25),
    );
    final metric = (Path()..addRRect(rrect)).computeMetrics().first;
    final len = metric.length;
    final head = progress.value * len;
    final tail = len * _tailFraction;

    for (var i = _pieces - 1; i >= 0; i--) {
      final t1 = head - tail * i / _pieces;
      final t0 = head - tail * (i + 1) / _pieces;
      final strength = pow(1 - i / _pieces, 1.6).toDouble();
      final pieceColor = Color.lerp(color, Colors.white, strength * 0.7)!;

      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 4
        ..color = color.withValues(alpha: 0.55 * strength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      _drawSegment(canvas, metric, t0, t1, glow);

      final core = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.6
        ..color = pieceColor.withValues(alpha: strength);
      _drawSegment(canvas, metric, t0, t1, core);
    }
  }

  @override
  bool shouldRepaint(covariant _LaserPainter old) =>
      old.color != color || old.radius != radius;
}
