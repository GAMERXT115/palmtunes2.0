import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';

import 'player_hub.dart';

/// Live punch level (0..1) of whatever Palm Tunes is playing.
///
/// Phones do not let an app listen to the system output (no WASAPI loopback),
/// so this taps the player itself: every player gets a pass-through audio
/// filter (`astats`) that leaves the sound untouched and only publishes its
/// loudness as metadata. [BassMeter] reads that ~30x per second and runs it
/// through the same fast-attack / fast-release envelope the desktop app used,
/// so the visuals hit on every kick.
///
/// If a build of libmpv does not ship that filter, the meter notices (no
/// numbers arrive) and switches to a gentle synthetic pulse so the UI still
/// moves. [usingFallback] tells you which one is running.
class BassMeter {
  static const String _label = 'bass';
  static const String _metaKey =
      'af-metadata/$_label/lavfi.astats.Overall.RMS_level';

  /// Puts the pass-through filter on a player. Safe to call on any player.
  static void attachFilter(Player player) {
    final native = player.platform;
    if (native is! NativePlayer) return;
    unawaited(() async {
      try {
        await native.setProperty(
          'af',
          '@$_label:lavfi=[astats=metadata=1:reset=1]',
        );
      } catch (e) {
        debugPrint('[PalmTunes] Could not attach the bass filter -> $e');
      }
    }());
  }

  static const Duration _tickEvery = Duration(milliseconds: 16);
  static const Duration _pollEvery = Duration(milliseconds: 33);
  static const double _floorDb = -46;
  static const double _minPeakDb = -26;
  static const double _peakFallDbPerSec = 4;
  static const double _punchRangeDb = 6;
  static const double _releaseSeconds = 0.07;
  static const int _missesBeforeFallback = 90;

  final PlayerHub hub;
  final ValueNotifier<double> level = ValueNotifier<double>(0);

  final Stopwatch _clock = Stopwatch()..start();
  Timer? _tickTimer;
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;
  bool _wantInput = false;
  bool _fallback = false;
  int _misses = 0;
  int _lastMs = 0;
  double _peak = _minPeakDb;
  double? _avg;
  double _env = 0;
  double _target = 0;

  bool get usingFallback => _fallback;

  BassMeter(this.hub) {
    hub.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    _wantInput = hub.current != null && hub.isPlaying;
    if (_wantInput) {
      _pollTimer ??= Timer.periodic(_pollEvery, (_) => _poll());
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
      _misses = 0;
    }
    if (_tickTimer == null && (_wantInput || _env > 0.004)) {
      _lastMs = _clock.elapsedMilliseconds;
      _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());
    }
  }

  Future<void> _poll() async {
    if (_polling || _disposed || !_wantInput) return;
    if (_fallback) {
      _push(_synthetic());
      return;
    }
    final native = hub.player.platform;
    if (native is! NativePlayer) {
      _fallback = true;
      return;
    }
    _polling = true;
    try {
      final raw = (await native.getProperty(_metaKey)).trim();
      final db = _parse(raw);
      if (db == null) {
        if (++_misses >= _missesBeforeFallback) {
          _fallback = true;
          debugPrint(
            '[PalmTunes] No loudness data from the player, using the synthetic visualizer.',
          );
        }
      } else {
        _misses = 0;
        _push(db);
      }
    } catch (_) {
      if (++_misses >= _missesBeforeFallback) _fallback = true;
    } finally {
      _polling = false;
    }
  }

  static double? _parse(String raw) {
    if (raw.isEmpty) return null;
    final lower = raw.toLowerCase();
    if (lower.contains('inf')) return -90;
    return double.tryParse(raw);
  }

  double _synthetic() {
    final t = _clock.elapsedMilliseconds / 1000.0;
    final beat = pow(max(0.0, sin(t * 2 * pi * 1.9)), 3).toDouble();
    return -30 + beat * 14 + Random().nextDouble() * 3;
  }

  void _push(double db) {
    _peak = max(_peak, db);
    final avg = _avg ?? db;
    _avg = avg + (db - avg) * 0.03;
    final absolute = ((db - _floorDb) / (_peak - _floorDb)).clamp(0.0, 1.0);
    final punch = ((db - avg) / _punchRangeDb).clamp(0.0, 1.0);
    final x = absolute * absolute * 0.5 + punch * 0.5;
    _target = max(_target, x.clamp(0.0, 1.0));
  }

  void _tick() {
    final now = _clock.elapsedMilliseconds;
    final dt = max(0.001, (now - _lastMs) / 1000.0);
    _lastMs = now;
    _peak = max(_minPeakDb, _peak - _peakFallDbPerSec * dt);

    final decayed = _env * exp(-dt / _releaseSeconds);
    _env = max(_target, decayed);
    _target = 0;

    if (!_wantInput && _env < 0.004) {
      _env = 0;
      level.value = 0;
      _tickTimer?.cancel();
      _tickTimer = null;
      return;
    }
    if ((level.value - _env).abs() > 0.003) level.value = _env;
  }

  void dispose() {
    _disposed = true;
    hub.removeListener(_sync);
    _tickTimer?.cancel();
    _pollTimer?.cancel();
    level.dispose();
  }
}

/// A row of bars that jump with the music. Each bar follows [level] with its
/// own delay and weight, so the row looks like a spectrum without needing one.
class BassBars extends StatefulWidget {
  final ValueListenable<double> level;
  final Color color;
  final int bars;
  final double height;
  final double barWidth;
  final double gap;

  const BassBars({
    super.key,
    required this.level,
    required this.color,
    this.bars = 24,
    this.height = 64,
    this.barWidth = 5,
    this.gap = 3,
  });

  @override
  State<BassBars> createState() => _BassBarsState();
}

class _BassBarsState extends State<BassBars>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late List<double> _values;
  late final List<double> _weights;
  final _rng = Random(7);

  @override
  void initState() {
    super.initState();
    _values = List.filled(widget.bars, 0);
    _weights = List.generate(widget.bars, (i) {
      // Louder in the middle, softer at the edges, with some variety.
      final c = (i - (widget.bars - 1) / 2).abs() / (widget.bars / 2);
      return (1 - c * 0.55) * (0.7 + _rng.nextDouble() * 0.3);
    });
    _ticker = createTicker(_onTick)..start();
  }

  Duration _last = Duration.zero;

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final lvl = widget.level.value;
    var changed = false;
    for (var i = 0; i < _values.length; i++) {
      final jitter = 0.82 + _rng.nextDouble() * 0.18;
      final target = (lvl * _weights[i] * jitter).clamp(0.0, 1.0);
      final cur = _values[i];
      final next = target > cur
          ? cur + (target - cur) * min(1.0, dt * 28)
          : cur + (target - cur) * min(1.0, dt * 9);
      if ((next - cur).abs() > 0.001) changed = true;
      _values[i] = next;
    }
    if (changed && mounted) setState(() {});
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final v in _values)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.gap / 2),
              child: Container(
                width: widget.barWidth,
                height: 4 + (widget.height - 4) * v,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.barWidth),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [
                      widget.color.withValues(alpha: 0.55),
                      widget.color,
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The round music-note logo that swells with the bass.
class BassLogo extends StatelessWidget {
  final ValueListenable<double> level;
  final Color color;
  final double size;

  const BassLogo({
    super.key,
    required this.level,
    required this.color,
    this.size = 32,
  });

  static const double _maxGrow = 0.18;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: level,
        builder: (context, v, child) => Transform.scale(
          scale: 1 + _maxGrow * v,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [color, color.withValues(alpha: 0.6)],
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.5 + 0.4 * v),
                  blurRadius: 12 + 12 * v,
                ),
              ],
            ),
            child: child,
          ),
        ),
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            Icons.music_note_rounded,
            color: Colors.white,
            size: size * 0.53,
          ),
        ),
      ),
    );
  }
}
