import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'settings.dart';

class AppColors {
  static const background = Color(0xFF0A0A0D);
  static const surface = Color(0xFF141014);
  static const panel = Color(0xFF1E1417);
  static const glassBase = Color(0x8C120C0E);
  static const success = Color(0xFF34D399);
}

class NotchMessage {
  final int id;
  final String text;
  final IconData icon;
  const NotchMessage(this.id, this.text, this.icon);
}

class Notch extends ChangeNotifier {
  Notch._();

  static final Notch instance = Notch._();

  NotchMessage? _message;
  bool _visible = false;
  Timer? _timer;
  int _seq = 0;

  NotchMessage? get message => _message;
  bool get visible => _visible;

  static void show(
    String text, {
    IconData icon = Icons.info_outline_rounded,
    Duration duration = const Duration(milliseconds: 2200),
  }) => instance._show(text, icon, duration);

  void _show(String text, IconData icon, Duration duration) {
    _timer?.cancel();
    _message = NotchMessage(++_seq, text, icon);
    _visible = true;
    notifyListeners();
    _timer = Timer(duration, hide);
  }

  void hide() {
    _timer?.cancel();
    if (!_visible) return;
    _visible = false;
    notifyListeners();
  }
}

enum _Cutout { none, notch, island }

/// Works out what is at the top edge of the screen from the safe-area inset:
/// iPhone X to 14 (and 16e) have a notch (inset 44 to 50), iPhone 14 Pro and
/// newer have the Dynamic Island (inset 54 to 62). Everything else gets the
/// plain pill below the status bar.
_Cutout _cutoutFor(BuildContext context) {
  if (defaultTargetPlatform != TargetPlatform.iOS) return _Cutout.none;
  final inset = MediaQuery.viewPaddingOf(context).top;
  if (inset >= 54) return _Cutout.island;
  if (inset >= 40) return _Cutout.notch;
  return _Cutout.none;
}

class NotchHost extends StatelessWidget {
  const NotchHost({super.key});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final cutout = _cutoutFor(context);
    final inset = MediaQuery.viewPaddingOf(context).top;

    if (cutout != _Cutout.none) {
      return Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: ListenableBuilder(
            listenable: Notch.instance,
            builder: (context, _) => _HardwareNotch(
              cutout: cutout,
              inset: inset,
              message: Notch.instance.message,
              visible: Notch.instance.visible,
              accent: accent,
            ),
          ),
        ),
      );
    }

    return Positioned(
      top: MediaQuery.paddingOf(context).top,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: ListenableBuilder(
          listenable: Notch.instance,
          builder: (context, _) {
            final n = Notch.instance;
            final m = n.message;
            return Center(
              child: AnimatedSlide(
                offset: n.visible ? Offset.zero : const Offset(0, -1.3),
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeInOut,
                child: AnimatedOpacity(
                  opacity: n.visible ? 1 : 0,
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeInOut,
                  child: m == null
                      ? const SizedBox.shrink()
                      : _NotchBody(message: m, accent: accent),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A solid black shape that grows out of the real notch / Dynamic Island, so
/// it looks like the hardware itself is expanding to show the message.
class _HardwareNotch extends StatelessWidget {
  final _Cutout cutout;
  final double inset;
  final NotchMessage? message;
  final bool visible;
  final Color accent;

  const _HardwareNotch({
    required this.cutout,
    required this.inset,
    required this.message,
    required this.visible,
    required this.accent,
  });

  static const double _islandW = 126;
  static const double _islandH = 37;
  static const double _islandTop = 11;
  static const double _notchW = 240;
  static const double _bandH = 36;

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final island = cutout == _Cutout.island;

    final collapsedW = island ? _islandW : _notchW;
    final collapsedH = island ? _islandH : inset - 4;
    final expandedW = island
        ? math.min(screenW - 24, 340.0)
        : math.min(screenW - 56, 340.0);
    final expandedH = island ? _islandH + _bandH + 4 : inset + _bandH;
    final width = visible ? expandedW : collapsedW;
    final height = visible ? expandedH : collapsedH;

    final radius = island
        ? BorderRadius.circular(visible ? 34 : _islandH / 2)
        : const BorderRadius.vertical(bottom: Radius.circular(28));

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.only(top: island ? _islandTop : 0),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 460),
          curve: Curves.easeInOutCubicEmphasized,
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: visible ? 0.28 : 0),
                blurRadius: 22,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minWidth: expandedW,
              maxWidth: expandedW,
              minHeight: expandedH,
              maxHeight: expandedH,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: Duration(milliseconds: visible ? 320 : 160),
                curve: visible ? const Interval(0.35, 1) : Curves.easeIn,
                child: Material(
                  type: MaterialType.transparency,
                  child: message == null
                      ? const SizedBox.shrink()
                      : (island
                            ? _islandContent(message!)
                            : _notchContent(message!)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _islandContent(NotchMessage m) {
    return Column(
      children: [
        // Top row sits beside the island: icon on its left, pulse on its right.
        SizedBox(
          height: _islandH,
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 18),
                    child: Icon(m.icon, size: 18, color: accent),
                  ),
                ),
              ),
              const SizedBox(width: _islandW),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 18),
                    child: Icon(
                      Icons.graphic_eq_rounded,
                      size: 18,
                      color: accent.withValues(alpha: 0.75),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
          child: _messageText(m),
        ),
      ],
    );
  }

  Widget _notchContent(NotchMessage m) {
    return Column(
      children: [
        SizedBox(height: inset - 2),
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(m.icon, size: 16, color: accent),
                  const SizedBox(width: 8),
                  Flexible(child: _messageText(m)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _messageText(NotchMessage m) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 200),
    child: Text(
      m.text,
      key: ValueKey(m.id),
      maxLines: 1,
      textAlign: TextAlign.center,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 13,
        fontWeight: FontWeight.w600,
        decoration: TextDecoration.none,
      ),
    ),
  );
}

class _NotchBody extends StatelessWidget {
  final NotchMessage message;
  final Color accent;

  const _NotchBody({required this.message, required this.accent});

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.vertical(bottom: Radius.circular(18));
    return Material(
      type: MaterialType.transparency,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(color: accent.withValues(alpha: 0.30), blurRadius: 22),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              constraints: const BoxConstraints(minWidth: 160, maxWidth: 340),
              padding: const EdgeInsets.fromLTRB(16, 9, 18, 10),
              decoration: BoxDecoration(
                color: const Color(0xE6120C0E),
                borderRadius: radius,
                border: Border.all(color: accent.withValues(alpha: 0.35)),
              ),
              child: AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeInOut,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeInOut,
                  child: Row(
                    key: ValueKey(message.id),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(message.icon, size: 16, color: accent),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          message.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.none,
                          ),
                        ),
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

ThemeData buildTheme(Color accent) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
      ).copyWith(
        primary: accent,
        onPrimary: Colors.white,
        surface: AppColors.surface,
        error: Colors.redAccent.shade200,
      );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.background,
    splashFactory: InkSparkle.splashFactory,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: accent,
      selectionColor: accent.withValues(alpha: 0.35),
      selectionHandleColor: accent,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        hoverColor: Colors.white.withValues(alpha: 0.08),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      width: 480,
      backgroundColor: AppColors.panel,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: accent.withValues(alpha: 0.35)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      decoration: BoxDecoration(
        color: AppColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: AppColors.panel,
      textStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(Colors.white24),
      radius: const Radius.circular(8),
      thickness: WidgetStateProperty.all(6),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: accent),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? accent : Colors.transparent,
      ),
      checkColor: WidgetStateProperty.all(Colors.white),
    ),
  );
}

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final double opacity;
  final Color? borderColor;
  final double? width;
  final double? height;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = 20,
    this.padding = EdgeInsets.zero,
    this.opacity = 0.08,
    this.borderColor,
    this.width,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final sigma = context.select<SettingsStore, double>((s) => s.glassBlur);
    final radius = BorderRadius.circular(borderRadius);
    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(
              Colors.white.withValues(alpha: opacity + 0.04),
              AppColors.glassBase,
            ),
            Color.alphaBlend(
              Colors.white.withValues(alpha: opacity * 0.5),
              AppColors.glassBase,
            ),
          ],
        ),
        border: Border.all(
          color: borderColor ?? Colors.white.withValues(alpha: 0.10),
        ),
      ),
      child: child,
    );

    if (sigma <= 0) {
      return ClipRRect(borderRadius: radius, child: content);
    }
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: content,
      ),
    );
  }
}

Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final danger = Colors.redAccent.shade200;
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassContainer(
            borderRadius: 20,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: danger.withValues(alpha: 0.15),
                      ),
                      child: Icon(
                        Icons.warning_amber_rounded,
                        color: danger,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white70,
                    height: 1.4,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      autofocus: true,
                      onPressed: () => Navigator.pop(ctx, false),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                      ),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx, true),
                      icon: const Icon(Icons.delete_outline_rounded, size: 18),
                      label: Text(confirmLabel),
                      style: FilledButton.styleFrom(backgroundColor: danger),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return result ?? false;
}

/// A picture that can be a web address or a file saved on the phone.
class ThumbImage extends StatelessWidget {
  final String source;
  final BoxFit fit;

  const ThumbImage({super.key, required this.source, this.fit = BoxFit.cover});

  Widget _placeholder() => Container(
    color: Colors.white.withValues(alpha: 0.06),
    alignment: Alignment.center,
    child: const Icon(
      Icons.music_note_rounded,
      color: Colors.white24,
      size: 26,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (source.isEmpty) return _placeholder();
    if (source.startsWith('http')) {
      return Image.network(
        source,
        fit: fit,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }
    return Image.file(
      File(source),
      fit: fit,
      errorBuilder: (_, _, _) => _placeholder(),
    );
  }
}
