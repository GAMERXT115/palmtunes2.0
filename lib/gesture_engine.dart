import 'dart:math' as math;

/// One hand landmark in "selfie view" (x grows to the user's right), the same
/// space the desktop script worked in after it flipped the camera frame.
class Pt {
  final double x;
  final double y;
  final double z;
  const Pt(this.x, this.y, this.z);
}

typedef Hand = List<Pt>;

typedef GestureSink = void Function(String name, Map<String, Object?> extra);

// ---------------------------------------------------------------------------
// Tuning (identical to palm_gestures.py)
// ---------------------------------------------------------------------------

const int _wrist = 0;
const Map<String, List<int>> _fingers = {
  'index': [5, 6, 7, 8],
  'middle': [9, 10, 11, 12],
  'ring': [13, 14, 15, 16],
  'pinky': [17, 18, 19, 20],
};

const Map<String?, int> _stableFrames = {
  'palm': 2,
  'fist': 2,
  'knob': 2,
  'point': 3,
  'peace': 4,
  'thumbs_up': 4,
  'other': 3,
  null: 4,
};
const double _actionCooldown = 1.2;
const double _swipeWindow = 0.45;
const double _swipeDistance = 0.18;
const double _swipeMaxSlope = 0.6;
const double _swipeCooldown = 0.9;
const double _pointGrace = 0.3;
const double _trailWindow = 0.8;
const double _eventLabelSeconds = 0.8;

const double _mutePalmHold = 0.2;
const double _muteLinkWindow = 0.5;
const int _muteFistFrames = 2;
const int _unmutePalmFrames = 2;
const double _muteRearmDelay = 0.6;
const double _fistCurlRatio = 1.0;
const int _fistMinCurled = 3;

const double _knobMaxSpread = 0.6;
const double _knobMinGap = 0.1;
const double _knobDepth = 0.15;
const double _knobMaxStraight = 0.9;
const double _knobHoldSpreadFactor = 1.3;
const double _knobHoldGapFactor = 0.9;
const double _knobHoldDepthFactor = 0.5;
const double _knobArmSeconds = 0.2;
const double _knobLostGrace = 0.35;
final double _knobStep = 10 * math.pi / 180;
final double _knobJitter = 1.5 * math.pi / 180;
final double _knobMaxJump = 90 * math.pi / 180;
const double _knobSmoothing = 0.65;
const double _knobCommitDelay = 0.25;
const double _knobReleaseGapDelta = 0.08;

const double _pinchOn = 0.30;
const double _pinchOff = 0.42;
const int _pinchConfirmFrames = 2;
const double _pinchSmoothing = 0.5;

const int _gateConfirmFrames = 2;
const double _handsMinSeparation = 0.15;
const double _thumbUpMargin = 0.15;

/// How much the in-app volume moves per knob step (percent).
const int volumeSnap = 5;

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

double _dist(Pt a, Pt b) =>
    math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

double _dist3(Pt a, Pt b) => math.sqrt(
  (a.x - b.x) * (a.x - b.x) +
      (a.y - b.y) * (a.y - b.y) +
      (a.z - b.z) * (a.z - b.z),
);

double _wrapAngle(double a) {
  while (a > math.pi) {
    a -= 2 * math.pi;
  }
  while (a < -math.pi) {
    a += 2 * math.pi;
  }
  return a;
}

double _handSize(Hand lm) => _dist(lm[_wrist], lm[9]);

double _palmSize3(Hand lm) =>
    (_dist3(lm[_wrist], lm[5]) +
        _dist3(lm[_wrist], lm[17]) +
        _dist3(lm[5], lm[17])) /
    3;

double _pinchValue(Hand lm) {
  final size = _palmSize3(lm);
  if (size < 1e-6) return 99;
  return math.min(_dist3(lm[4], lm[8]), _dist3(lm[4], lm[12])) / size;
}

bool _fingerExtended(Hand lm, List<int> ids) {
  final wrist = lm[_wrist];
  return _dist(wrist, lm[ids[3]]) > _dist(wrist, lm[ids[1]]) * 1.15;
}

double _fingerStraightness(Hand lm, List<int> ids) {
  final length =
      _dist3(lm[ids[0]], lm[ids[1]]) +
      _dist3(lm[ids[1]], lm[ids[2]]) +
      _dist3(lm[ids[2]], lm[ids[3]]);
  if (length < 1e-6) return 0;
  return _dist3(lm[ids[0]], lm[ids[3]]) / length;
}

bool _thumbExtended(Hand lm) {
  final palmWidth = _dist(lm[5], lm[17]);
  final farFromIndex = _dist(lm[4], lm[5]) > palmWidth * 0.65;
  final beyondJoint = _dist(lm[4], lm[17]) > _dist(lm[3], lm[17]);
  return farFromIndex && beyondJoint;
}

int _fistCurlCount(Hand lm) {
  final wrist = lm[_wrist];
  var curled = 0;
  for (final ids in _fingers.values) {
    if (_dist3(wrist, lm[ids[3]]) <
        _dist3(wrist, lm[ids[0]]) * _fistCurlRatio) {
      curled++;
    }
  }
  return curled;
}

bool _isTightFist(Hand lm) => _fistCurlCount(lm) >= _fistMinCurled;

bool _isThumbsUp(Hand lm) {
  if (_fingers.values.any((ids) => _fingerExtended(lm, ids))) return false;
  if (!_thumbExtended(lm)) return false;
  if (!(lm[4].y < lm[3].y && lm[3].y < lm[2].y)) return false;
  var top = double.infinity;
  for (var i = 5; i < 21; i++) {
    top = math.min(top, lm[i].y);
  }
  return lm[4].y < top - _thumbUpMargin * _handSize(lm);
}

({double spread, double gap, double depth}) _knobMetrics(Hand lm) {
  final size = _handSize(lm);
  if (size < 1e-6) return (spread: 99.0, gap: 0.0, depth: 0.0);
  final tips = [lm[4], lm[8], lm[12]];
  final cx = tips.fold<double>(0, (a, t) => a + t.x) / 3;
  final cy = tips.fold<double>(0, (a, t) => a + t.y) / 3;
  var spread = 0.0;
  for (final t in tips) {
    spread = math.max(
      spread,
      math.sqrt((t.x - cx) * (t.x - cx) + (t.y - cy) * (t.y - cy)),
    );
  }
  spread /= size;
  final gap = _dist(lm[4], lm[8]) / size;
  final tipZ = (lm[4].z + lm[8].z + lm[12].z) / 3;
  final knuckleZ = (lm[5].z + lm[9].z) / 2;
  final depth = (knuckleZ - tipZ) / size;
  return (spread: spread, gap: gap, depth: depth);
}

bool _fingersStraightForV(Hand lm) =>
    _fingerStraightness(lm, _fingers['index']!) > _knobMaxStraight &&
    _fingerStraightness(lm, _fingers['middle']!) > _knobMaxStraight;

bool _isKnob(Hand lm) {
  if (_fingersStraightForV(lm)) return false;
  final m = _knobMetrics(lm);
  return m.spread <= _knobMaxSpread &&
      m.gap >= _knobMinGap &&
      m.depth >= _knobDepth;
}

bool _knobHeld(Hand lm) {
  final m = _knobMetrics(lm);
  return m.spread <= _knobMaxSpread * _knobHoldSpreadFactor &&
      m.gap >= _knobMinGap * _knobHoldGapFactor &&
      m.depth >= _knobDepth * _knobHoldDepthFactor;
}

double _knobAngle(Hand lm) {
  final mx = (lm[8].x + lm[12].x) / 2;
  final my = (lm[8].y + lm[12].y) / 2;
  return math.atan2(my - lm[4].y, mx - lm[4].x);
}

/// 'knob', 'palm', 'thumbs_up', 'fist', 'peace', 'point' or 'other'.
String classifyHand(Hand lm) {
  if (_isKnob(lm)) return 'knob';
  final ext = {
    for (final e in _fingers.entries) e.key: _fingerExtended(lm, e.value),
  };
  final thumb = _thumbExtended(lm);
  final count = ext.values.where((v) => v).length;
  if (count == 4 && thumb) return 'palm';
  if (count == 0) {
    final pointingUp =
        thumb && lm[4].y < lm[2].y - 0.04 && lm[4].y < lm[_wrist].y;
    return pointingUp ? 'thumbs_up' : 'fist';
  }
  if (ext['index']! && ext['middle']! && !ext['ring']! && !ext['pinky']!)
    return 'peace';
  if (ext['index']! && !ext['middle']! && !ext['ring']! && !ext['pinky']!)
    return 'point';
  return 'other';
}

String? _twoHandPose(Hand a, Hand b) {
  if ((a[_wrist].x - b[_wrist].x).abs() < _handsMinSeparation) return null;
  if (classifyHand(a) == 'palm' && classifyHand(b) == 'palm') return 'palms';
  if (_isThumbsUp(a) && _isThumbsUp(b)) return 'thumbs';
  return null;
}

// ---------------------------------------------------------------------------
// Pinch lock: while pinching the knob must not start
// ---------------------------------------------------------------------------

class PinchDetector {
  double on = _pinchOn;
  double off = _pinchOff;
  double? raw;
  double? value;
  bool active = false;
  int frames = 0;

  void reset() {
    raw = null;
    value = null;
    active = false;
    frames = 0;
  }

  bool update(Hand? lm) {
    if (lm == null) {
      reset();
      return false;
    }
    raw = _pinchValue(lm);
    value = value == null
        ? raw
        : value! * _pinchSmoothing + raw! * (1 - _pinchSmoothing);
    if (active) {
      if (value! > off) {
        active = false;
        frames = 0;
      }
      return active;
    }
    if (value! < on) {
      frames++;
      if (frames >= _pinchConfirmFrames) active = true;
    } else {
      frames = 0;
    }
    return active;
  }
}

// ---------------------------------------------------------------------------
// Two palms / two thumbs-up put the controls to sleep or wake them
// ---------------------------------------------------------------------------

class ControlGate {
  ControlGate(this._emit);

  final GestureSink _emit;
  bool enabled = true;
  int _frames = 0;
  String? lastPose;

  String get _wanted => enabled ? 'palms' : 'thumbs';

  /// Returns 'controls_on' / 'controls_off' when the state flips.
  String? update(List<Hand> hands) {
    final pose = hands.length == 2 ? _twoHandPose(hands[0], hands[1]) : null;
    lastPose = pose;
    if (pose != _wanted) {
      _frames = 0;
      return null;
    }
    _frames++;
    if (_frames < _gateConfirmFrames) return null;
    _frames = 0;
    enabled = !enabled;
    final name = enabled ? 'controls_on' : 'controls_off';
    _emit(name, const {});
    return name;
  }
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

class GestureEngine {
  GestureEngine(this._emit);

  final GestureSink _emit;
  final PinchDetector pinch = PinchDetector();

  String? _candidate;
  int _candidateFrames = 0;
  String? pose;
  final Map<String, double> _lastAction = {};
  bool mutedByGesture = false;
  double? _palmSince;
  int _palmFrames = 0;
  double _armedPalmSeen = -1e9;
  int _fistFrames = 0;
  double _muteBlockUntil = 0;
  List<(double, double, double)> _trail = [];
  double _lastSwipe = 0;
  double _pointSeen = -1e9;
  bool pointing = false;
  double swipeDx = 0;
  double? _knobSince;
  double? _knobLostSince;
  bool knobReady = false;
  double? _knobPrev;
  double? _knobPrevGap;
  double _knobTotal = 0;
  double _knobRef = 0;
  double _knobSmoothed = 0;
  (bool, double)? _knobPending;
  bool pinched = false;
  String _lastLabel = '';
  double _lastLabelTime = 0;

  double get knobDegrees => (_knobTotal - _knobRef) * 180 / math.pi;
  bool get knobActive => _knobSince != null;

  void note(String label, double now) {
    _lastLabel = label;
    _lastLabelTime = now;
  }

  /// Short text for the preview overlay ("NEXT", "VOL +", "HOLD KNOB 0.1s").
  String label(double now) {
    final since = _knobSince;
    if (since != null && !knobReady) {
      final left = math.max(0.0, _knobArmSeconds - (now - since));
      return 'HOLD KNOB ${left.toStringAsFixed(1)}s';
    }
    if (now - _lastLabelTime <= _eventLabelSeconds) return _lastLabel;
    if (!mutedByGesture && now - _armedPalmSeen <= _muteLinkWindow) {
      return 'FIST TO MUTE';
    }
    return '';
  }

  void _resetMuteTracking() {
    _palmSince = null;
    _palmFrames = 0;
    _armedPalmSeen = -1e9;
    _fistFrames = 0;
  }

  void suspend(double now) {
    _releaseKnob();
    _resetMuteTracking();
    _trail.clear();
    _pointSeen = -1e9;
    pointing = false;
    swipeDx = 0;
    _candidate = null;
    _candidateFrames = 0;
    pose = null;
    pinched = false;
    pinch.reset();
    note('SLEEP', now);
  }

  void _fire(String name, double now, [Map<String, Object?> extra = const {}]) {
    if (now - (_lastAction[name] ?? 0) < _actionCooldown) return;
    _lastAction[name] = now;
    note(name.toUpperCase(), now);
    _emit(name, extra);
  }

  bool _updateMute(Hand? lm, String? raw, double now) {
    if (raw == 'palm') {
      _palmSince ??= now;
      _palmFrames++;
    } else {
      _palmSince = null;
      _palmFrames = 0;
    }
    if (mutedByGesture) {
      if (_palmFrames >= _unmutePalmFrames) {
        mutedByGesture = false;
        _muteBlockUntil = now + _muteRearmDelay;
        _armedPalmSeen = -1e9;
        _fistFrames = 0;
        note('MUTE OFF', now);
        _emit('mute_off', const {});
      }
      return false;
    }
    if (raw == 'palm' &&
        now - _palmSince! >= _mutePalmHold &&
        now >= _muteBlockUntil) {
      _armedPalmSeen = now;
    }
    final fist = lm != null && _isTightFist(lm);
    if (fist && now - _armedPalmSeen <= _muteLinkWindow) {
      _fistFrames++;
      if (_fistFrames >= _muteFistFrames) {
        _fistFrames = 0;
        _armedPalmSeen = -1e9;
        mutedByGesture = true;
        note('MUTE ON', now);
        _emit('mute_on', const {});
        return true;
      }
    } else {
      _fistFrames = 0;
    }
    return false;
  }

  bool _updatePointing(Hand? lm, String? raw, double now) {
    if (raw == 'point') _pointSeen = now;
    final recent = now - _pointSeen <= _pointGrace;
    final indexUp = lm != null && _fingerExtended(lm, _fingers['index']!);
    pointing = recent && indexUp;
    return recent;
  }

  /// Feed one frame. [lm] is the single visible hand, or null when there is
  /// no hand (or two, which only the [ControlGate] looks at).
  String? update(Hand? lm, double now) {
    final raw = lm != null ? classifyHand(lm) : null;
    final recentPoint = _updatePointing(lm, raw, now);
    if (_updateMute(lm, raw, now)) _releaseKnob();
    pinched = pinch.update(pointing ? null : lm);
    if (pinched && _knobSince != null) {
      _releaseKnob();
      note('PINCH LOCK', now);
    }
    final knobSeen =
        lm != null &&
        !pointing &&
        !pinched &&
        !mutedByGesture &&
        (raw == 'knob' || (_knobSince != null && _knobHeld(lm)));
    _trackKnob(knobSeen ? lm : null, now);
    final effective = _knobSince != null ? 'knob' : raw;
    if (effective == _candidate) {
      _candidateFrames++;
    } else {
      _candidate = effective;
      _candidateFrames = 1;
    }
    if (_candidateFrames >= (_stableFrames[effective] ?? 4) &&
        effective != pose) {
      _onPose(effective, now);
      pose = effective;
    }
    _updateSwipe(lm, recentPoint, now);
    return pose;
  }

  void _updateSwipe(Hand? lm, bool recentPoint, double now) {
    final blocked = _knobSince != null || mutedByGesture;
    if (pointing && !blocked && lm != null) {
      _trackPoint(lm[8], now);
    } else if (!recentPoint || blocked) {
      _trail.clear();
      swipeDx = 0;
    }
  }

  void _onPose(String? next, double now) {
    if (next == 'peace') {
      _fire('pause', now);
    } else if (next == 'thumbs_up') {
      _fire('play', now);
    }
  }

  void _releaseKnob() {
    _knobSince = null;
    _knobLostSince = null;
    knobReady = false;
    _knobPrev = null;
    _knobPrevGap = null;
    _knobTotal = 0;
    _knobRef = 0;
    _knobSmoothed = 0;
    _knobPending = null;
  }

  void _pauseKnob() {
    _knobPrev = null;
    _knobPrevGap = null;
    _knobSmoothed = 0;
    _knobPending = null;
  }

  void _stepVolume(bool up, double now) {
    note(up ? 'VOL +' : 'VOL -', now);
    _emit('volume', {'delta': up ? volumeSnap : -volumeSnap});
  }

  void _trackKnob(Hand? lm, double now) {
    if (lm == null) {
      if (_knobSince == null) return;
      _knobLostSince ??= now;
      _pauseKnob();
      if (now - _knobLostSince! > _knobLostGrace) _releaseKnob();
      return;
    }
    _knobLostSince = null;
    final angle = _knobAngle(lm);
    final gap = _knobMetrics(lm).gap;
    _knobSince ??= now;
    if (_knobPrevGap != null &&
        (gap - _knobPrevGap!).abs() > _knobReleaseGapDelta) {
      _pauseKnob();
      _knobPrevGap = gap;
      _knobPrev = angle;
      return;
    }
    _knobPrevGap = gap;
    if (!knobReady) {
      _knobPrev = angle;
      if (now - _knobSince! < _knobArmSeconds) return;
      knobReady = true;
      _knobTotal = 0;
      _knobRef = 0;
      _knobSmoothed = 0;
      _knobPending = null;
      note('KNOB READY', now);
      return;
    }
    if (_knobPrev == null) {
      _knobPrev = angle;
      return;
    }
    var delta = _wrapAngle(angle - _knobPrev!);
    _knobPrev = angle;
    if (delta.abs() > _knobMaxJump) {
      _knobPending = null;
      return;
    }
    if (delta.abs() < _knobJitter) delta = 0;
    _knobSmoothed =
        _knobSmoothed * _knobSmoothing + delta * (1 - _knobSmoothing);
    _knobTotal += _knobSmoothed;
    final offset = _knobTotal - _knobRef;
    if (offset.abs() < _knobStep) {
      _knobPending = null;
      return;
    }
    // On the phone camera view a turn to the user's RIGHT makes the angle
    // shrink (offset < 0). Turning right must raise the volume and turning
    // left must lower it, so volume goes up when the offset is negative.
    final clockwise = offset > 0;
    final up = !clockwise;
    final pending = _knobPending;
    if (pending == null || pending.$1 != up) {
      _knobPending = (up, now);
      return;
    }
    if (now - pending.$2 < _knobCommitDelay) return;
    _knobPending = null;
    _knobRef += clockwise ? _knobStep : -_knobStep;
    _stepVolume(up, now);
  }

  void _trackPoint(Pt tip, double now) {
    _trail.add((now, tip.x, tip.y));
    _trail = _trail.where((p) => now - p.$1 <= _trailWindow).toList();
    (double, double, double)? start;
    for (final p in _trail) {
      if (now - p.$1 <= _swipeWindow) {
        start = p;
        break;
      }
    }
    if (start == null) {
      swipeDx = 0;
      return;
    }
    final last = _trail.last;
    final dx = last.$2 - start.$2;
    final dy = last.$3 - start.$3;
    swipeDx = dx;
    if (now - _lastSwipe < _swipeCooldown) return;
    if (dx.abs() < _swipeDistance || dy.abs() > dx.abs() * _swipeMaxSlope)
      return;
    _lastSwipe = now;
    final name = dx > 0 ? 'next' : 'previous';
    note(name.toUpperCase(), now);
    _emit(name, const {});
    _trail.clear();
    swipeDx = 0;
  }
}
