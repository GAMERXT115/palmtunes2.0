import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'ui.dart';

/// One beat of the intro music: when it lands (seconds from the start of
/// assets/intro.mp3) and how hard it hits.
class _Hit {
  final double t;
  final double power;
  const _Hit(this.t, [this.power = 1]);
}

/// The beat map of assets/intro.mp3 (130 BPM, music runs to ~5.7 s, then a
/// quiet bell ring-out). Measured from the audio itself, so the splash is
/// drawn from these times instead of from guesses. Keep the lists sorted.
class _IntroScore {
  _IntroScore._();

  /// Seconds the pictures are held back. The speaker is a little behind the
  /// clock, so a small positive value makes the flash land with the sound.
  /// Raise it if things flash BEFORE you hear them, lower it (even below 0)
  /// if they flash after. Bluetooth headphones need a much larger value.
  static const double visualDelay = 0.06;

  /// Kick / sub-bass thumps (and the little drum roll at 1.5-1.85 s).
  static const List<_Hit> bass = [
    _Hit(0.49, 0.7),
    _Hit(0.95, 0.8),
    _Hit(1.30, 0.8),
    _Hit(1.50, 0.4),
    _Hit(1.63, 0.6),
    _Hit(1.74, 0.5),
    _Hit(1.85, 0.9),
    _Hit(3.29, 1.0),
    _Hit(3.64, 0.8),
  ];

  /// The plucked bell hits.
  static const List<_Hit> bells = [
    _Hit(0.93, 0.8),
    _Hit(2.30, 1.0),
    _Hit(3.23, 1.0),
    _Hit(3.70, 0.6),
    _Hit(4.16, 1.0),
  ];

  /// Stretches where the bass note climbs (D3 / E3 over the B2 / C3 root).
  static const List<(double, double)> lifts = [
    (0.50, 1.45),
    (2.10, 2.60),
    (4.00, 4.45),
  ];

  /// The text, ring and sparks start collapsing on this kick...
  static const double collapseAt = 3.29;

  /// ...and the logo zooms open where the last bass lift ends, so the app is
  /// fully revealed over the closing hits at 5.1 - 5.5 s.
  static const double zoomAt = 4.46;

  /// 0..1 punch of the most recent hit, falling off over about [decay] seconds.
  static double pulse(List<_Hit> hits, double t, double decay) {
    var v = 0.0;
    for (final h in hits) {
      final age = t - h.t;
      if (age < 0) break;
      v = max(v, h.power * exp(-age / decay));
    }
    return v;
  }

  /// 0..1, smoothly up while the bass note is lifted.
  static double lift(double t) {
    var v = 0.0;
    for (final (a, b) in lifts) {
      final up = Curves.easeInOut.transform(((t - a) / 0.12).clamp(0.0, 1.0));
      final down = Curves.easeInOut.transform(((b - t) / 0.20).clamp(0.0, 1.0));
      v = max(v, min(up, down));
    }
    return v;
  }
}

/// Shows the splash while [boot] loads the app, then the logo zooms in until
/// it is off screen and the app shows through it.
///
/// The whole thing is played to assets/intro.mp3: the logo punches and sends
/// out a ring on every kick, the bells throw sparks, and the zoom into the
/// app is timed to the closing hits (see [_IntroScore]).
class SplashLauncher extends StatefulWidget {
  final Color accent;
  final Future<Widget> Function() boot;

  const SplashLauncher({super.key, required this.accent, required this.boot});

  @override
  State<SplashLauncher> createState() => _SplashLauncherState();
}

class _SplashLauncherState extends State<SplashLauncher>
    with TickerProviderStateMixin {
  static const double _logoSize = 120;
  static const double _ringSize = 150;

  // Zoom-through reveal. The logo's white (the palm tree) becomes a
  // see-through cut-out, so the app shows through it as the logo grows.
  static const double _zoomMax = 140;
  // Point of the logo the zoom heads into (inside the palm's crown).
  static const Alignment _zoomAnchor = Alignment(0, -0.2);
  // Alpha from brightness: ~white => 1, the red/dark parts => 0.
  static const ColorFilter _whiteMask = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    1.5, 2.95, 0.55, 0, -918,
  ]);
  // The opposite: everything except the white.
  static const ColorFilter _notWhiteMask = ColorFilter.matrix(<double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    -1.5, -2.95, -0.55, 0, 1173,
  ]);

  // Intro (logo spins and bounces in, then the title and subtitle).
  late final AnimationController _main = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3000),
  );
  // Welding ring and sparks.
  late final AnimationController _welding = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4000),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2000),
  );
  late final AnimationController _card = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  late final Animation<double> _fadeIn = CurvedAnimation(
    parent: _main,
    curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
  );
  late final Animation<double> _scaleAnim = Tween<double>(begin: 0.2, end: 1)
      .animate(
        CurvedAnimation(
          parent: _main,
          curve: const Interval(0.0, 0.6, curve: Curves.elasticOut),
        ),
      );
  late final Animation<double> _rotation = Tween<double>(begin: 0, end: pi * 2)
      .animate(
        CurvedAnimation(
          parent: _main,
          curve: const Interval(0.0, 0.5, curve: Curves.easeInOutBack),
        ),
      );
  // The title lands as the drum roll ends (~1.85 s of the music).
  late final Animation<double> _titleOpacity = CurvedAnimation(
    parent: _main,
    curve: const Interval(0.5, 0.64, curve: Curves.easeIn),
  );
  late final Animation<Offset> _titleSlide =
      Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _main,
          curve: const Interval(0.5, 0.66, curve: Curves.easeOutCubic),
        ),
      );
  // The subtitle arrives with the first full bell hit (2.30 s).
  late final Animation<double> _subtitleOpacity = CurvedAnimation(
    parent: _main,
    curve: const Interval(0.77, 0.9, curve: Curves.easeIn),
  );
  late final Animation<Offset> _subtitleSlide =
      Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _main,
          curve: const Interval(0.77, 1.0, curve: Curves.easeOutCubic),
        ),
      );
  late final Animation<double> _glow = Tween<double>(
    begin: 1,
    end: 1.5,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  late final Animation<double> _bounce = Tween<double>(
    begin: -6,
    end: 6,
  ).animate(CurvedAnimation(parent: _wave, curve: Curves.easeInOut));

  Color get _primary => widget.accent;
  Color get _light => Color.lerp(widget.accent, Colors.white, 0.45)!;
  Color get _soft => Color.lerp(widget.accent, Colors.white, 0.75)!;

  /// Runs from the moment the music starts; everything that follows the beat
  /// reads its time from here (see [_now]).
  final Stopwatch _clock = Stopwatch();
  Player? _audio;

  Widget? _app;
  bool _done = false;
  bool _zooming = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _pulse.repeat(reverse: true);
    _wave.repeat(reverse: true);
    unawaited(_startIntro());
    unawaited(_run());
  }

  @override
  void dispose() {
    _clock.stop();
    unawaited(_releaseAudio());
    _main.dispose();
    _welding.dispose();
    _pulse.dispose();
    _wave.dispose();
    _card.dispose();
    _reveal.dispose();
    super.dispose();
  }

  /// Seconds of music played so far (0 until it starts).
  double get _now => _clock.isRunning
      ? _clock.elapsedMicroseconds / 1e6 - _IntroScore.visualDelay
      : 0;

  Future<void> _waitUntil(double seconds) async {
    while (mounted && _now < seconds) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
    }
  }

  /// Loads the music first, then starts the music, the clock and the pictures
  /// in the same instant. If the music cannot be loaded the splash still
  /// plays, just silently, on the same clock.
  Future<void> _startIntro() async {
    Player? audio;
    try {
      audio = Player();
      _audio = audio;
      await audio
          .open(Media('asset:///assets/intro.mp3'), play: false)
          .timeout(const Duration(seconds: 2));
      unawaited(
        audio.stream.completed
            .firstWhere((done) => done, orElse: () => false)
            .then((_) => _releaseAudio()),
      );
    } catch (e) {
      debugPrint('[PalmTunes] Intro music not loaded -> $e');
      unawaited(_releaseAudio());
      audio = null;
    }
    if (!mounted) return;
    try {
      await audio?.play();
    } catch (_) {}
    _clock.start();
    _main.forward();
    _welding.repeat();
  }

  Future<void> _releaseAudio() async {
    final a = _audio;
    _audio = null;
    try {
      await a?.dispose();
    } catch (_) {}
  }

  Future<void> _run() async {
    try {
      final app = await widget.boot();
      // Hold until the music reaches the kick the collapse is timed to. If
      // the app loaded slowly this returns at once and it just goes ahead.
      await _waitUntil(_IntroScore.collapseAt);
      if (!mounted) return;
      await _transition(app);
    } catch (e, st) {
      debugPrint('[PalmTunes] Startup failed -> $e\n$st');
      await _fail(e);
    }
  }

  Future<void> _fail(Object e) async {
    unawaited(_releaseAudio());
    if (mounted) setState(() => _error = e);
  }

  Future<void> _transition(Widget app) async {
    // 1. On the kick: text, ring and sparks fade out and the logo settles in
    // the middle.
    await _card.forward();
    if (!mounted) return;

    // 2. The app is mounted but hidden until the zoom starts. The logo keeps
    // pulsing to the bass and the bells while it waits.
    setState(() => _app = app);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    // 3. On the beat the logo zooms in until it is off screen. The app is
    // only visible inside the growing logo (and through its palm tree), so it
    // is revealed by the zoom itself, with nothing else drawn behind.
    await _waitUntil(_IntroScore.zoomAt);
    if (!mounted) return;
    setState(() => _zooming = true);
    await _reveal.forward();
    if (!mounted) return;
    setState(() => _done = true);
  }

  double _zoomScale(double t) =>
      0.88 * pow(_zoomMax / 0.88, Curves.easeInQuad.transform(t)).toDouble();

  /// The part of the screen where the app is visible: the logo's disc while it
  /// grows, then everything.
  Path _portal(Size size) {
    if (_done) return Path()..addRect(Offset.zero & size);
    final half = _logoSize / 2;
    final s = _zoomScale(_reveal.value);
    final center =
        size.center(Offset.zero) +
        Offset(_zoomAnchor.x * half, _zoomAnchor.y * half) * (1 - s);
    return Path()..addOval(Rect.fromCircle(center: center, radius: half * s));
  }

  Widget _logoImage() {
    return Image.asset(
      'assets/logo.png',
      width: _logoSize,
      height: _logoSize,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stack) => Icon(
        Icons.music_note_rounded,
        size: _logoSize * 0.7,
        color: _primary,
      ),
    );
  }

  /// The zoom: the logo's red disc without its palm tree, scaled up around the
  /// palm's crown. The app (clipped to the same disc, see [_portal]) shows
  /// through the palm; the white palm is drawn over it for the first instant
  /// so the switch from the normal logo is not visible.
  Widget _zoomLayer() {
    final t = _reveal.value;
    final scale = _zoomScale(t);
    // The disc only fades once it is bigger than the screen, so what is left
    // is the app.
    final fade =
        1 - Curves.easeIn.transform(((t - 0.80) / 0.20).clamp(0.0, 1.0));
    final palm = 1 - (t / 0.12).clamp(0.0, 1.0);

    Widget scaled(Widget child) => SizedBox.expand(
      child: Center(
        child: Transform.scale(
          scale: scale,
          alignment: _zoomAnchor,
          child: SizedBox(width: _logoSize, height: _logoSize, child: child),
        ),
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Opacity(
          opacity: fade,
          child: scaled(
            ClipOval(
              child: ColorFiltered(
                colorFilter: _notWhiteMask,
                child: _logoImage(),
              ),
            ),
          ),
        ),
        if (palm > 0)
          Opacity(
            opacity: palm,
            child: scaled(
              ColorFiltered(colorFilter: _whiteMask, child: _logoImage()),
            ),
          ),
      ],
    );
  }

  Widget _splashLayer() {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth;
        final h = c.maxHeight;
        return AnimatedBuilder(
          animation: Listenable.merge([
            _main,
            _welding,
            _pulse,
            _wave,
            _card,
            _reveal,
          ]),
          builder: (context, _) {
            if (_zooming) return _zoomLayer();
            final a = Curves.easeInOutCubic.transform(_card.value);
            final rest = (1 - a).clamp(0.0, 1.0);

            // What the music is doing right now.
            final now = _now;
            final bass = _IntroScore.pulse(_IntroScore.bass, now, 0.16);
            final bell = _IntroScore.pulse(_IntroScore.bells, now, 0.28);
            final lift = _IntroScore.lift(now);
            final glowBoost = min(1.2, max(bass, 0.8 * bell) + 0.25 * lift);

            final home = Offset(w / 2, h * 0.40);
            final logoC = Offset.lerp(home, Offset(w / 2, h / 2), a)!;
            return Stack(
              fit: StackFit.expand,
              children: [
                // Kick rings and bell sparks, behind everything else.
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _BeatPainter(
                        t: now,
                        center: logoC,
                        radius: _ringSize / 2,
                        color: _light,
                        fade: 0.4 + 0.6 * _fadeIn.value,
                      ),
                    ),
                  ),
                ),
                // Title and subtitle under the logo.
                Positioned(
                  left: 0,
                  right: 0,
                  top: home.dy + _ringSize / 2 + 34,
                  child: Opacity(
                    opacity: rest,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FadeTransition(
                          opacity: _titleOpacity,
                          child: SlideTransition(
                            position: _titleSlide,
                            child: ShaderMask(
                              shaderCallback: (bounds) => LinearGradient(
                                colors: [_soft, _light, _primary],
                                stops: const [0.0, 0.5, 1.0],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ).createShader(bounds),
                              child: const Text(
                                'Palm Tunes',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        FadeTransition(
                          opacity: _subtitleOpacity,
                          child: SlideTransition(
                            position: _subtitleSlide,
                            child: Text(
                              'Music in Your Pocket.',
                              style: TextStyle(
                                color: _soft,
                                fontSize: 14,
                                letterSpacing: 0.5,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Logo with the welding ring: spins in, bobs, and jumps and
                // swells on every kick.
                Positioned(
                  left: logoC.dx - _ringSize / 2,
                  top: logoC.dy - _ringSize / 2,
                  width: _ringSize,
                  height: _ringSize,
                  child: Transform.translate(
                    offset: Offset(0, _bounce.value * rest - 7 * bass),
                    child: FadeTransition(
                      opacity: _fadeIn,
                      child: Transform.scale(
                        scale:
                            _scaleAnim.value *
                            (1 - 0.12 * a) *
                            (1 + 0.10 * bass),
                        child: Transform.rotate(
                          angle: _rotation.value,
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: [
                              _logo(rest, glowBoost),
                              CustomPaint(
                                size: const Size(_ringSize, _ringSize),
                                painter: _WeldingRingPainter(
                                  t: _welding.value,
                                  // The ring flares on every bell.
                                  color: _light.withValues(
                                    alpha:
                                        (0.6 + 0.4 * bell).clamp(0.0, 1.0) *
                                        rest,
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
                // Ambient sparks flying out of the logo (kept calm so the
                // beat-driven effects stand out).
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _SparkPainter(
                        t: _welding.value,
                        center: logoC,
                        color: _light,
                        fade: rest * _fadeIn.value * 0.55,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _logo(double fade, double boost) {
    return Container(
      width: _logoSize,
      height: _logoSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: _primary.withValues(
              alpha: (0.5 * _glow.value * fade + 0.45 * boost).clamp(0.0, 1.0),
            ),
            blurRadius: 30 * _glow.value + 22 * boost,
            spreadRadius: 5 * _glow.value + 7 * boost,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_logoSize / 2),
        child: Image.asset(
          'assets/logo.png',
          width: _logoSize,
          height: _logoSize,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stack) => Icon(
            Icons.music_note_rounded,
            size: _logoSize * 0.7,
            color: _primary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_app != null)
            Positioned.fill(
              child: Offstage(
                offstage: !_zooming,
                child: ClipPath(
                  clipper: _PortalClipper(_portal, _reveal),
                  child: ClipRect(child: _app),
                ),
              ),
            ),
          if (_error != null)
            Positioned.fill(
              child: ColoredBox(
                color: AppColors.background,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Palm Tunes could not start.\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        height: 1.4,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            )
          else if (!_done)
            Positioned.fill(
              child: IgnorePointer(
                ignoring: _card.value >= 1,
                child: _splashLayer(),
              ),
            ),
        ],
      ),
    );
  }
}

class _PortalClipper extends CustomClipper<Path> {
  final Path Function(Size) build;
  _PortalClipper(this.build, Listenable reclip) : super(reclip: reclip);

  @override
  Path getClip(Size size) => build(size);

  @override
  bool shouldReclip(covariant _PortalClipper oldClipper) => true;
}

class _SparkParticle {
  final double angle;
  final double speed;
  final double offset;
  final double size;
  const _SparkParticle(this.angle, this.speed, this.offset, this.size);
}

/// The dashed ring that runs around the logo.
class _WeldingRingPainter extends CustomPainter {
  final double t;
  final Color color;
  const _WeldingRingPainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    final paint = Paint()
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const segmentCount = 25;
    const segmentLength = 12.0;
    const emptyLength = 8.0;
    for (var i = 0; i < segmentCount; i++) {
      final start = (t * 360 + i * (segmentLength + emptyLength)) * pi / 180;
      paint.color = color.withValues(alpha: color.a * (1.0 - i / segmentCount));
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        start,
        segmentLength * pi / 180,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WeldingRingPainter old) =>
      old.t != t || old.color != color;
}

/// The effects that follow the music: a ring leaves the logo on every kick
/// and a burst of sparks flies out on every bell. [t] is the time of the music
/// in seconds, the hits come from [_IntroScore]. Rings and bursts are shrunk
/// to fit when the screen is narrow, so a phone never clips them.
class _BeatPainter extends CustomPainter {
  final double t;
  final Offset center;
  final double radius;
  final Color color;
  final double fade;

  const _BeatPainter({
    required this.t,
    required this.center,
    required this.radius,
    required this.color,
    required this.fade,
  });

  static const double _ringLife = 0.7;
  static const double _burstLife = 1.0;

  // One fixed burst of sparks per bell, so it looks the same every launch.
  static final List<List<_SparkParticle>> _bursts = List.generate(
    _IntroScore.bells.length,
    (i) {
      final r = Random(40 + i);
      return List.generate(
        20,
        (_) => _SparkParticle(
          r.nextDouble() * 2 * pi,
          r.nextDouble() * 2 + 1,
          r.nextDouble(),
          r.nextDouble() * 1.6 + 1.2,
        ),
      );
    },
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0) return;

    // How far the effects may travel before they would leave a narrow screen.
    final room = max(30.0, size.width / 2 - radius - 6);

    // Bass: a ring grows out of the logo and fades.
    final ring = Paint()..style = PaintingStyle.stroke;
    for (final h in _IntroScore.bass) {
      final age = t - h.t;
      if (age < 0) break;
      if (age > _ringLife) continue;
      final k = age / _ringLife;
      final power = h.power.clamp(0.0, 1.0);
      ring
        ..strokeWidth = 1 + 3.5 * (1 - k)
        ..color = color.withValues(
          alpha: ((1 - k) * 0.6 * power * fade).clamp(0.0, 1.0),
        );
      canvas.drawCircle(
        center,
        radius + Curves.easeOutCubic.transform(k) * min(60 + 70 * power, room),
        ring,
      );
    }

    // Bells: a burst of twinkling sparks.
    final fit = min(1.0, room / 165);
    final dot = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < _IntroScore.bells.length; i++) {
      final h = _IntroScore.bells[i];
      final age = t - h.t;
      if (age < 0) break;
      if (age > _burstLife) continue;
      final k = age / _burstLife;
      final out = Curves.easeOutCubic.transform(k);
      final power = h.power.clamp(0.0, 1.0);
      for (final p in _bursts[i]) {
        final d = radius + out * (50 + p.speed * 38) * fit;
        final pos = center + Offset(cos(p.angle), sin(p.angle)) * d;
        final twinkle = 0.65 + 0.35 * sin(age * 38 + p.offset * 2 * pi);
        dot.color = color.withValues(
          alpha: ((1 - k) * twinkle * power * fade).clamp(0.0, 1.0),
        );
        canvas.drawCircle(pos, p.size * (1 - 0.55 * k), dot);
      }
    }
  }

  @override
  bool shouldRepaint(_BeatPainter old) =>
      old.t != t || old.center != center || old.fade != fade;
}

/// Small sparks that fly out of the logo and fade away.
class _SparkPainter extends CustomPainter {
  final double t;
  final Offset center;
  final Color color;
  final double fade;

  const _SparkPainter({
    required this.t,
    required this.center,
    required this.color,
    required this.fade,
  });

  static final List<_SparkParticle> _particles = () {
    final r = Random(5);
    return List.generate(
      50,
      (_) => _SparkParticle(
        r.nextDouble() * 2 * pi,
        r.nextDouble() * 2 + 1,
        r.nextDouble(),
        r.nextDouble() * 2 + 1,
      ),
    );
  }();

  @override
  void paint(Canvas canvas, Size size) {
    if (fade <= 0) return;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final p in _particles) {
      final progress = (t + p.offset) % 1.0;
      // Kept near the logo: 120 to 220 px away.
      final distance = progress * (70 + p.speed * 50);
      final pos = center + Offset(cos(p.angle), sin(p.angle)) * distance;
      paint.color = color.withValues(
        alpha: ((1.0 - progress) * fade).clamp(0.0, 1.0),
      );
      canvas.drawCircle(pos, p.size, paint);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => true;
}
