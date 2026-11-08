import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gesture_engine.dart';
import 'hand_tracker.dart';
import 'player_hub.dart';
import 'ui.dart';

enum GestureStatus {
  off,
  starting,
  ready,
  noCamera,
  noPermission,
  unsupported,
  crashed,
}

/// Turns the phone camera into the Palm Tunes remote.
///
/// Camera frames -> [HandTracker] (MediaPipe) -> [GestureEngine] -> player.
/// The same bridge also feeds the "Preview Cam" card in Settings.
class GestureBridge extends ChangeNotifier with WidgetsBindingObserver {
  static const _kEnabled = 'pt_camera_gestures';
  static const _kLens = 'pt_camera_lens';
  static const _kFlip = 'pt_swipe_flip';

  final PlayerHub hub;
  SharedPreferences? _prefs;

  bool _enabled = false;
  bool _previewWanted = false;
  bool _flipSwipe = false;
  CameraLensDirection _lens = CameraLensDirection.front;
  GestureStatus _status = GestureStatus.off;
  String? _lastError;
  int _session = 0;
  bool _starting = false;
  bool _background = false;

  CameraController? _controller;
  CameraDescription? _description;
  HandTracker? _tracker;
  StreamSubscription<List<Hand>>? _handsSub;
  Timer? _watchdog;
  late final GestureEngine _engine = GestureEngine(_onGesture);
  late final ControlGate _gate = ControlGate(_onGesture);
  final Stopwatch _clock = Stopwatch()..start();
  double _lastResult = 0;

  /// Hands of the latest frame in selfie view, for drawing on the preview.
  final ValueNotifier<List<Hand>> handsNow = ValueNotifier<List<Hand>>(
    const [],
  );

  /// What the engine is doing right now ("NEXT", "VOL +", "SLEEP"...).
  final ValueNotifier<String> hint = ValueNotifier<String>('');

  GestureBridge(this.hub);

  bool get enabled => _enabled;
  bool get previewing => _previewWanted;
  bool get flipSwipe => _flipSwipe;
  CameraLensDirection get lens => _lens;
  GestureStatus get status => _status;
  String? get lastError => _lastError;
  CameraController? get controller => _controller;
  bool get asleep => !_gate.enabled;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    _enabled = _prefs!.getBool(_kEnabled) ?? false;
    _flipSwipe = _prefs!.getBool(_kFlip) ?? false;
    final lens = _prefs!.getString(_kLens);
    _lens = lens == 'back'
        ? CameraLensDirection.back
        : CameraLensDirection.front;
    WidgetsBinding.instance.addObserver(this);
    if (!HandTracker.supported) {
      _status = GestureStatus.unsupported;
      return;
    }
    if (_enabled) unawaited(_start());
  }

  // ---- settings -----------------------------------------------------------

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    _prefs?.setBool(_kEnabled, value);
    notifyListeners();
    if (value) {
      if (_controller != null) {
        // A preview-only run keeps its camera; the engine just starts acting.
        _setStatus(GestureStatus.ready);
        Notch.show('Camera gestures on', icon: Icons.back_hand_rounded);
      } else {
        await _start();
      }
    } else {
      if (_previewWanted) {
        _setStatus(GestureStatus.ready);
      } else {
        await _stop();
        _setStatus(GestureStatus.off);
      }
      Notch.show('Camera gestures off', icon: Icons.videocam_off_rounded);
    }
  }

  Future<void> setPreview(bool on) async {
    if (_previewWanted == on) return;
    _previewWanted = on;
    notifyListeners();
    if (on) {
      if (_controller == null) await _start();
    } else {
      handsNow.value = const [];
      if (!_enabled) {
        await _stop();
        _setStatus(GestureStatus.off);
      }
    }
  }

  Future<void> setLens(CameraLensDirection lens) async {
    if (_lens == lens) return;
    _lens = lens;
    _prefs?.setString(
      _kLens,
      lens == CameraLensDirection.back ? 'back' : 'front',
    );
    notifyListeners();
    if (_enabled || _previewWanted) {
      await _stop();
      await _start();
    }
  }

  void setFlipSwipe(bool v) {
    _flipSwipe = v;
    _prefs?.setBool(_kFlip, v);
    notifyListeners();
  }

  // ---- camera lifecycle ---------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Phones do not let apps use the camera in the background.
    if (state == AppLifecycleState.resumed) {
      if (_background && (_enabled || _previewWanted)) {
        _background = false;
        unawaited(_start());
      }
      _background = false;
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (_controller != null) {
        _background = true;
        unawaited(_stop());
      }
    }
  }

  void _setStatus(GestureStatus s, [String? error]) {
    _status = s;
    _lastError = error;
    notifyListeners();
  }

  Future<void> _start() async {
    if (_starting || _controller != null) return;
    if (!HandTracker.supported) {
      _setStatus(GestureStatus.unsupported);
      return;
    }
    _starting = true;
    final session = ++_session;
    _setStatus(GestureStatus.starting);
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _setStatus(GestureStatus.noCamera);
        Notch.show(
          'No camera found for gestures',
          icon: Icons.videocam_off_rounded,
        );
        return;
      }
      final desc = cams.firstWhere(
        (c) => c.lensDirection == _lens,
        orElse: () => cams.first,
      );
      final tracker = HandTracker.create();
      final controller = CameraController(
        desc,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: tracker.imageFormat,
      );
      await controller.initialize();
      if (session != _session) {
        await controller.dispose();
        await tracker.dispose();
        return;
      }
      _description = desc;
      _tracker = tracker;
      _controller = controller;
      _handsSub = tracker.hands.listen(_onHands);
      _lastResult = _clock.elapsedMilliseconds / 1000.0;
      _watchdog = Timer.periodic(const Duration(milliseconds: 120), (_) {
        // The tracker may stay silent when no hand is visible.
        final now = _clock.elapsedMilliseconds / 1000.0;
        if (now - _lastResult > 0.25) _onHands(const []);
      });
      await controller.startImageStream((image) {
        if (hub.isFullscreen) return;
        tracker.process(image, desc.sensorOrientation);
      });
      _setStatus(GestureStatus.ready);
      if (_enabled) {
        Notch.show('Camera gestures on', icon: Icons.back_hand_rounded);
      }
    } on CameraException catch (e) {
      final denied = e.code.toLowerCase().contains('access');
      await _stop();
      _setStatus(
        denied ? GestureStatus.noPermission : GestureStatus.crashed,
        e.description ?? e.code,
      );
      Notch.show(
        denied ? 'Camera permission is off' : 'Camera gestures stopped',
        icon: Icons.error_outline_rounded,
      );
    } catch (e) {
      await _stop();
      _setStatus(GestureStatus.crashed, '$e');
      Notch.show('Camera gestures stopped', icon: Icons.error_outline_rounded);
    } finally {
      _starting = false;
    }
  }

  Future<void> _stop() async {
    _session++;
    _watchdog?.cancel();
    _watchdog = null;
    await _handsSub?.cancel();
    _handsSub = null;
    final controller = _controller;
    final tracker = _tracker;
    _controller = null;
    _tracker = null;
    _description = null;
    handsNow.value = const [];
    hint.value = '';
    notifyListeners();
    try {
      if (controller != null) {
        if (controller.value.isStreamingImages)
          await controller.stopImageStream();
        await controller.dispose();
      }
    } catch (_) {}
    await tracker?.dispose();
  }

  // ---- results ------------------------------------------------------------

  void _onHands(List<Hand> raw) {
    _lastResult = _clock.elapsedMilliseconds / 1000.0;
    final mirror = _description?.lensDirection == CameraLensDirection.front;
    final hands = mirror
        ? [
            for (final h in raw) [for (final p in h) Pt(1 - p.x, p.y, p.z)],
          ]
        : raw;
    handsNow.value = hands;
    if (!_enabled) return;
    final now = _lastResult;
    final change = _gate.update(hands);
    if (change == 'controls_off') {
      _engine.suspend(now);
    } else if (change == 'controls_on') {
      _engine.note('AWAKE', now);
    }
    if (_gate.enabled) {
      _engine.update(hands.length == 1 ? hands.first : null, now);
    }
    hint.value = _gate.enabled ? _engine.label(now) : 'SLEEP  show 2 thumbs up';
  }

  void _onGesture(String name, Map<String, Object?> extra) {
    switch (name) {
      case 'volume':
        final delta = (extra['delta'] as num?)?.toInt() ?? 0;
        if (delta != 0) hub.changeVolume(delta);
      case 'pause':
        if (hub.current == null || !hub.isPlaying) return;
        hub.pause();
        Notch.show('Paused', icon: Icons.pause_rounded);
      case 'play':
        if (hub.current == null || hub.isPlaying) return;
        hub.play();
        Notch.show('Playing', icon: Icons.play_arrow_rounded);
      case 'next':
        if (hub.current == null) return;
        if (_flipSwipe) {
          _goPrevious();
        } else {
          _goNext();
        }
      case 'previous':
        if (hub.current == null) return;
        if (_flipSwipe) {
          _goNext();
        } else {
          _goPrevious();
        }
      case 'mute_on':
        hub.setMuted(true);
      case 'mute_off':
        hub.setMuted(false);
      case 'controls_on':
        Notch.show('Gestures awake', icon: Icons.back_hand_rounded);
      case 'controls_off':
        Notch.show('Gestures asleep', icon: Icons.bedtime_rounded);
    }
  }

  void _goNext() {
    if (!hub.hasNext) return;
    Notch.show('Next', icon: Icons.skip_next_rounded);
    hub.next();
  }

  void _goPrevious() {
    Notch.show(
      hub.hasPrevious ? 'Previous' : 'Restart',
      icon: hub.hasPrevious
          ? Icons.skip_previous_rounded
          : Icons.replay_rounded,
    );
    hub.previousTrack();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stop();
    handsNow.dispose();
    hint.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// "Preview Cam": a card that slides down from the top and shows the camera
// with the detected hands drawn on it.
// ---------------------------------------------------------------------------

class CameraPreviewHost extends StatelessWidget {
  const CameraPreviewHost({super.key});

  @override
  Widget build(BuildContext context) {
    final bridge = context.watch<GestureBridge>();
    final show = bridge.previewing;
    final top = MediaQuery.paddingOf(context).top + 8;
    return Positioned(
      top: top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedSlide(
          offset: show ? Offset.zero : const Offset(0, -1.6),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeInOut,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: const Duration(milliseconds: 280),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _PreviewCard(bridge: bridge),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final GestureBridge bridge;
  const _PreviewCard({required this.bridge});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final controller = bridge.controller;
    final ready = controller != null && controller.value.isInitialized;
    return Material(
      type: MaterialType.transparency,
      child: GlassContainer(
        borderRadius: 20,
        padding: const EdgeInsets.all(8),
        borderColor: accent.withValues(alpha: 0.35),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.back_hand_rounded, size: 16, color: accent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Preview Cam',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => bridge.setPreview(false),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: Colors.white70,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: ready
                    ? Stack(
                        fit: StackFit.expand,
                        children: [
                          FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width:
                                  controller.value.previewSize?.height ?? 480,
                              height:
                                  controller.value.previewSize?.width ?? 640,
                              child: _selfieView(controller),
                            ),
                          ),
                          ValueListenableBuilder<List<Hand>>(
                            valueListenable: bridge.handsNow,
                            builder: (_, hands, _) => CustomPaint(
                              painter: _HandsPainter(hands, accent),
                            ),
                          ),
                          Positioned(
                            left: 10,
                            top: 8,
                            child: ValueListenableBuilder<String>(
                              valueListenable: bridge.hint,
                              builder: (_, text, _) => AnimatedOpacity(
                                opacity: text.isEmpty ? 0 : 1,
                                duration: const Duration(milliseconds: 150),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    text,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Container(
                        color: Colors.black,
                        alignment: Alignment.center,
                        child: Text(switch (bridge.status) {
                          GestureStatus.noPermission =>
                            'Camera permission is off',
                          GestureStatus.noCamera => 'No camera found',
                          GestureStatus.unsupported => 'Not supported here',
                          GestureStatus.crashed => 'Camera stopped',
                          _ => 'Starting camera...',
                        }, style: const TextStyle(color: Colors.white60)),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Android shows the front camera un-mirrored; the hands are mirrored for the
/// engine (selfie view), so mirror the picture too and the two line up.
Widget _selfieView(CameraController controller) {
  final preview = CameraPreview(controller);
  final front = controller.description.lensDirection == CameraLensDirection.front;
  return (Platform.isAndroid && front)
      ? Transform.flip(flipX: true, child: preview)
      : preview;
}

class _HandsPainter extends CustomPainter {
  final List<Hand> hands;
  final Color color;
  _HandsPainter(this.hands, this.color);

  static const _bones = [
    [0, 1],
    [1, 2],
    [2, 3],
    [3, 4],
    [0, 5],
    [5, 6],
    [6, 7],
    [7, 8],
    [5, 9],
    [9, 10],
    [10, 11],
    [11, 12],
    [9, 13],
    [13, 14],
    [14, 15],
    [15, 16],
    [13, 17],
    [17, 18],
    [18, 19],
    [19, 20],
    [0, 17],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final dot = Paint()..color = Colors.white;
    // Hands were mirrored for the front camera before they got here, and the
    // camera plugin shows the front preview mirrored too, so they line up.
    Offset map(Pt p) => Offset(p.x * size.width, p.y * size.height);

    for (final h in hands) {
      for (final b in _bones) {
        canvas.drawLine(map(h[b[0]]), map(h[b[1]]), line);
      }
      for (final p in h) {
        canvas.drawCircle(map(p), math.max(2.0, size.width * 0.007), dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _HandsPainter old) => true;
}
