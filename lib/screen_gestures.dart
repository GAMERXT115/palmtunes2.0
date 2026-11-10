import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Touch gestures on the picture:
///
///  * one finger drawing a full circle clockwise, then keep circling:
///    the volume goes up (counter-clockwise: it goes down)
///  * one finger swipe right = next song, swipe left = previous song
///  * two fingers swipe down = pause, two fingers swipe up = play
///
/// It only listens to the raw touches, so taps, double taps and the long
/// press hold on the video keep working underneath.
class ScreenGestures extends StatefulWidget {
  final Widget child;
  final bool enabled;

  /// Called for every step while circling. [up] is true for clockwise.
  final void Function(bool up) onVolumeStep;
  final VoidCallback onCircleStart;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onPause;
  final VoidCallback onPlay;

  const ScreenGestures({
    super.key,
    required this.child,
    required this.onVolumeStep,
    required this.onCircleStart,
    required this.onNext,
    required this.onPrevious,
    required this.onPause,
    required this.onPlay,
    this.enabled = true,
  });

  @override
  State<ScreenGestures> createState() => _ScreenGesturesState();
}

class _ScreenGesturesState extends State<ScreenGestures> {
  // Tuning
  static const double _fullCircle = 2 * math.pi;
  static const double _circleNeeded = 0.92 * _fullCircle;
  static const double _stepAngle = 0.5; // radians per volume step (~29 deg)
  static const double _minRadius = 18;
  static const double _minSegment = 4;
  static const int _window = 36;
  static const double _swipeMin = 70;
  static const double _swipeSlope = 0.6;
  static const Duration _swipeMaxTime = Duration(milliseconds: 700);
  static const double _twoFingerMin = 60;

  final Map<int, Offset> _pointers = {};

  // one finger
  final List<Offset> _path = [];
  Offset _start = Offset.zero;
  DateTime _startTime = DateTime.now();
  double _cum = 0;
  double _acc = 0;
  bool _circle = false;
  bool _multi = false;

  // two fingers
  final Map<int, Offset> _twoStart = {};
  bool _twoDone = false;

  void _resetSingle(Offset p) {
    _path
      ..clear()
      ..add(p);
    _start = p;
    _startTime = DateTime.now();
    _cum = 0;
    _acc = 0;
    _circle = false;
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 1) {
      _multi = false;
      _resetSingle(e.position);
    } else {
      _multi = true;
      _circle = false;
      if (_pointers.length == 2) {
        _twoStart
          ..clear()
          ..addAll(_pointers);
        _twoDone = false;
      }
    }
  }

  void _move(PointerMoveEvent e) {
    if (!widget.enabled || !_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.position;
    if (_pointers.length == 1 && !_multi) {
      _trackCircle(e.position);
    } else if (_pointers.length == 2) {
      _trackTwo();
    }
  }

  void _up(PointerEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    final wasSingle = _pointers.length == 1 && !_multi;
    final end = _pointers[e.pointer]!;
    _pointers.remove(e.pointer);
    if (_pointers.isEmpty) {
      if (wasSingle && !_circle && e is PointerUpEvent) _checkSwipe(end);
      _multi = false;
      _circle = false;
      _twoDone = false;
      _twoStart.clear();
    }
  }

  void _checkSwipe(Offset end) {
    if (DateTime.now().difference(_startTime) > _swipeMaxTime) return;
    final d = end - _start;
    final adx = d.dx.abs();
    final ady = d.dy.abs();
    if (adx < _swipeMin || ady > adx * _swipeSlope) return;
    if (d.dx > 0) {
      widget.onNext();
    } else {
      widget.onPrevious();
    }
  }

  double _wrap(double a) {
    while (a > math.pi) {
      a -= 2 * math.pi;
    }
    while (a < -math.pi) {
      a += 2 * math.pi;
    }
    return a;
  }

  void _trackCircle(Offset p) {
    if (_path.isNotEmpty && (p - _path.last).distance < _minSegment) return;
    _path.add(p);
    if (_path.length > _window) _path.removeAt(0);
    if (_path.length < 8) return;

    var cx = 0.0;
    var cy = 0.0;
    for (final q in _path) {
      cx += q.dx;
      cy += q.dy;
    }
    cx /= _path.length;
    cy /= _path.length;
    final c = Offset(cx, cy);

    var radius = 0.0;
    var length = 0.0;
    for (var i = 0; i < _path.length; i++) {
      radius += (_path[i] - c).distance;
      if (i > 0) length += (_path[i] - _path[i - 1]).distance;
    }
    radius /= _path.length;
    if (radius < _minRadius) {
      if (!_circle) _cum = 0;
      return;
    }
    // A straight line is not a circle.
    final straightness = length <= 0
        ? 1.0
        : (_path.last - _path.first).distance / length;
    if (!_circle && straightness > 0.85) {
      _cum = 0;
      return;
    }

    final prev = _path[_path.length - 2];
    final a1 = math.atan2(prev.dy - c.dy, prev.dx - c.dx);
    final a2 = math.atan2(p.dy - c.dy, p.dx - c.dx);
    final d = _wrap(a2 - a1);

    if (!_circle) {
      _cum += d;
      if (_cum.abs() >= _circleNeeded) {
        _circle = true;
        _acc = 0;
        widget.onCircleStart();
      }
      return;
    }
    _acc += d;
    while (_acc.abs() >= _stepAngle) {
      final up = _acc > 0; // clockwise on screen
      _acc -= up ? _stepAngle : -_stepAngle;
      widget.onVolumeStep(up);
    }
  }

  void _trackTwo() {
    if (_twoDone || _twoStart.length != 2) return;
    var sum = 0.0;
    var agree = 0;
    var dirs = 0;
    for (final id in _pointers.keys) {
      final s = _twoStart[id];
      final now = _pointers[id];
      if (s == null || now == null) return;
      final dy = now.dy - s.dy;
      sum += dy;
      if (dy.abs() > _twoFingerMin * 0.6) {
        agree += dy > 0 ? 1 : -1;
        dirs++;
      }
    }
    final avg = sum / _pointers.length;
    if (dirs < 2 || agree.abs() != 2) return;
    if (avg > _twoFingerMin) {
      _twoDone = true;
      widget.onPause();
    } else if (avg < -_twoFingerMin) {
      _twoDone = true;
      widget.onPlay();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.child,
    );
  }
}
