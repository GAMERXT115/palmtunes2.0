import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'player_hub.dart';
import 'yt_streams.dart';

/// Live bass level (0..1) of whatever Palm Tunes is playing.
///
/// This is real: the song's own audio is decoded on the phone (Android
/// MediaCodec / iOS AVFoundation, in `packages/palmtunes_hands`), run through
/// the same 150 Hz low-pass the desktop meter used, and turned into one
/// loudness number every 20 ms. While the song plays, the meter reads that
/// list at the current position and feeds it through the desktop app's
/// fast-attack / fast-release envelope, so the visuals hit on every kick.
///
/// A song needs a few seconds of analysis the first time it plays (streamed
/// songs are fetched once more for this). Until that is ready the level stays
/// at zero, it is never faked.
class BassMeter {
  /// Kept so the player can call it; the player's own audio is never touched.
  static void attachFilter(Player player) {}

  static const MethodChannel _channel = MethodChannel('palmtunes/bass');
  static const double _windowMs = 20;
  static const int _lookAheadMs = 40;
  static const int _cacheSongs = 12;

  static const Duration _tickEvery = Duration(milliseconds: 16);
  static const Duration _pollEvery = Duration(milliseconds: 33);
  static const double _floorDb = -46;
  static const double _minPeakDb = -26;
  static const double _peakFallDbPerSec = 4;
  static const double _punchRangeDb = 6;
  static const double _releaseSeconds = 0.07;

  final PlayerHub hub;
  final ValueNotifier<double> level = ValueNotifier<double>(0);

  final Map<String, Float64List> _cache = {};
  final List<String> _cacheOrder = [];
  String? _forId;
  String? _analyzingId;
  Float64List? _env;

  final Stopwatch _clock = Stopwatch()..start();
  Timer? _tickTimer;
  Timer? _pollTimer;
  bool _disposed = false;
  bool _wantInput = false;
  int _lastMs = 0;
  double _peak = _minPeakDb;
  double? _avg;
  double _env01 = 0;
  double _target = 0;

  BassMeter(this.hub) {
    hub.addListener(_sync);
    _sync();
  }

  void _sync() {
    if (_disposed) return;
    final item = hub.current;
    if (item?.videoId != _forId) {
      _forId = item?.videoId;
      _env = _forId == null ? null : _cache[_forId];
      _peak = _minPeakDb;
      _avg = null;
    }
    if (item != null && _env == null && _analyzingId != item.videoId) {
      final src = hub.audioSource;
      if (src != null && !hub.isLoading) {
        unawaited(_analyze(item.videoId, src.uri, src.headers));
      }
    }

    _wantInput = item != null && hub.isPlaying && _env != null;
    if (_wantInput) {
      _pollTimer ??= Timer.periodic(_pollEvery, (_) => _poll());
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
    if (_tickTimer == null && (_wantInput || _env01 > 0.004)) {
      _lastMs = _clock.elapsedMilliseconds;
      _tickTimer = Timer.periodic(_tickEvery, (_) => _tick());
    }
  }

  Future<void> _analyze(
    String id,
    String source,
    Map<String, String>? headers,
  ) async {
    _analyzingId = id;
    File? temp;
    try {
      var path = source;
      if (source.startsWith('http')) {
        final dir = await getTemporaryDirectory();
        temp = File(p.join(dir.path, 'bass_$id.bin'));
        final sink = temp.openWrite();
        try {
          await sink.addStream(
            YtStreams.instance.openRanged(source, 0, headers ?? const {}),
          );
        } finally {
          await sink.close();
        }
        path = temp.path;
      }
      final raw = await _channel.invokeMethod<Object>('envelope', {
        'path': path,
        'windowMs': _windowMs,
      });
      final env = raw is Float64List
          ? raw
          : (raw is List
                ? Float64List.fromList(raw.cast<num>().map((e) => e.toDouble()).toList())
                : null);
      if (env == null || env.isEmpty) {
        debugPrint('[PalmTunes] Bass analysis for $id returned nothing');
        return;
      }
      _cache[id] = env;
      _cacheOrder
        ..remove(id)
        ..add(id);
      while (_cacheOrder.length > _cacheSongs) {
        _cache.remove(_cacheOrder.removeAt(0));
      }
      debugPrint('[PalmTunes] Bass analysis ready for $id (${env.length} frames)');
      if (!_disposed && _forId == id) {
        _env = env;
        _sync();
      }
    } catch (e) {
      debugPrint('[PalmTunes] Bass analysis failed for $id -> $e');
    } finally {
      try {
        await temp?.delete();
      } catch (_) {}
      if (_analyzingId == id && _env == null) {
        // Leave _analyzingId set so a failing song is not retried in a loop.
      }
    }
  }

  void _poll() {
    final env = _env;
    if (env == null || !_wantInput) return;
    final ms = hub.player.state.position.inMilliseconds + _lookAheadMs;
    final i = (ms / _windowMs).floor();
    if (i < 0 || i >= env.length) return;
    _push(env[i]);
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

    final decayed = _env01 * exp(-dt / _releaseSeconds);
    _env01 = max(_target, decayed);
    _target = 0;

    if (!_wantInput && _env01 < 0.004) {
      _env01 = 0;
      level.value = 0;
      _tickTimer?.cancel();
      _tickTimer = null;
      return;
    }
    if ((level.value - _env01).abs() > 0.003) level.value = _env01;
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
