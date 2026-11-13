import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'ui.dart';

/// Shows the splash while [boot] loads the app, then the logo zooms in until
/// it is off screen and the app shows through it.
class SplashLauncher extends StatefulWidget {
  final Color accent;
  final Future<Widget> Function() boot;
  final Duration minDuration;

  const SplashLauncher({
    super.key,
    required this.accent,
    required this.boot,
    this.minDuration = const Duration(milliseconds: 3600),
  });

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
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    1.5,
    2.95,
    0.55,
    0,
    -918,
  ]);
  // The opposite: everything except the white.
  static const ColorFilter _notWhiteMask = ColorFilter.matrix(<double>[
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    -1.5,
    -2.95,
    -0.55,
    0,
    1173,
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
  late final Animation<double> _titleOpacity = CurvedAnimation(
    parent: _main,
    curve: const Interval(0.5, 0.7, curve: Curves.easeIn),
  );
  late final Animation<Offset> _titleSlide =
      Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _main,
          curve: const Interval(0.5, 0.8, curve: Curves.easeOutCubic),
        ),
      );
  late final Animation<double> _subtitleOpacity = CurvedAnimation(
    parent: _main,
    curve: const Interval(0.7, 0.9, curve: Curves.easeIn),
  );
  late final Animation<Offset> _subtitleSlide =
      Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _main,
          curve: const Interval(0.7, 1.0, curve: Curves.easeOutCubic),
        ),
      );
  late final Animation<double> _glow = Tween<double>(
    begin: 1,
    end: 1.5,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  late final Animation<double> _bounce = Tween<double>(
    begin: -10,
    end: 10,
  ).animate(CurvedAnimation(parent: _wave, curve: Curves.easeInOut));

  Color get _primary => widget.accent;
  Color get _light => Color.lerp(widget.accent, Colors.white, 0.45)!;
  Color get _dark => Color.lerp(widget.accent, Colors.black, 0.5)!;
  Color get _soft => Color.lerp(widget.accent, Colors.white, 0.75)!;

  Widget? _app;
  bool _done = false;
  bool _zooming = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _main.forward();
    _welding.repeat();
    _pulse.repeat(reverse: true);
    _wave.repeat(reverse: true);
    unawaited(_run());
  }

  @override
  void dispose() {
    _main.dispose();
    _welding.dispose();
    _pulse.dispose();
    _wave.dispose();
    _card.dispose();
    _reveal.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final started = DateTime.now();
    try {
      final app = await widget.boot();
      final left = widget.minDuration - DateTime.now().difference(started);
      if (left > Duration.zero) await Future<void>.delayed(left);
      if (!mounted) return;
      await _transition(app);
    } catch (e, st) {
      debugPrint('[PalmTunes] Startup failed -> $e\n$st');
      await _fail(e);
    }
  }

  Future<void> _fail(Object e) async {
    if (mounted) setState(() => _error = e);
  }

  Future<void> _transition(Widget app) async {
    // 1. Text, ring and sparks fade out and the logo settles in the middle.
    await _card.forward();
    if (!mounted) return;

    // 2. The app is mounted but hidden until the zoom starts.
    setState(() => _app = app);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;

    // 3. The logo zooms in until it is off screen. The app is only visible
    // inside the growing logo (and through its palm tree), so it is revealed
    // by the zoom itself, with nothing else drawn behind.
    setState(() => _zooming = true);
    await _reveal.forward();
    if (!mounted) return;
    setState(() => _done = true);
  }

  double _zoomScale(double t) =>
      0.88 * pow(_zoomMax / 0.88, Curves.easeInQuad.transform(t)).toDouble();

  /// The part of the window where the app is visible: the logo's disc while it
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
    // The disc only fades once it is bigger than the window, so what is left
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

            final home = Offset(w / 2, h * 0.40);
            final logoC = Offset.lerp(home, Offset(w / 2, h / 2), a)!;
            return Stack(
              fit: StackFit.expand,
              children: [
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
                // Logo with the welding ring: spins in, then bobs.
                Positioned(
                  left: logoC.dx - _ringSize / 2,
                  top: logoC.dy - _ringSize / 2,
                  width: _ringSize,
                  height: _ringSize,
                  child: Transform.translate(
                    offset: Offset(0, _bounce.value * rest),
                    child: FadeTransition(
                      opacity: _fadeIn,
                      child: Transform.scale(
                        scale: _scaleAnim.value * (1 - 0.12 * a),
                        child: Transform.rotate(
                          angle: _rotation.value,
                          child: Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: [
                              _logo(rest),
                              CustomPaint(
                                size: const Size(_ringSize, _ringSize),
                                painter: _WeldingRingPainter(
                                  t: _welding.value,
                                  color: _light.withValues(alpha: 0.6 * rest),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Sparks flying out of the logo.
                IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _SparkPainter(
                        t: _welding.value,
                        center: logoC,
                        color: _light,
                        fade: rest * _fadeIn.value,
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

  Widget _logo(double fade) {
    return Container(
      width: _logoSize,
      height: _logoSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: _primary.withValues(alpha: 0.5 * _glow.value * fade),
            blurRadius: 30 * _glow.value,
            spreadRadius: 5 * _glow.value,
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
