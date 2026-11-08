import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hand_landmarker/hand_landmarker.dart' as hl;

import 'gesture_engine.dart';

/// Finds hands in camera frames and reports the 21 MediaPipe landmarks of each.
///
/// Both implementations return landmarks in the upright camera image,
/// NOT mirrored. [GestureBridge] mirrors them for the front camera so the
/// engine always works in selfie view, like the desktop script did.
abstract class HandTracker {
  Stream<List<Hand>> get hands;

  /// Whether this platform has a tracker at all.
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  static HandTracker create() =>
      Platform.isIOS ? IosHandTracker() : AndroidHandTracker();

  /// Camera format the tracker wants.
  ImageFormatGroup get imageFormat;

  void process(CameraImage image, int sensorOrientation);

  Future<void> dispose();
}

/// Android: MediaPipe Hand Landmarker through the `hand_landmarker` plugin.
class AndroidHandTracker implements HandTracker {
  late final hl.HandLandmarkerPlugin _plugin = hl.HandLandmarkerPlugin.create(
    numHands: 2,
    minHandDetectionConfidence: 0.7,
    delegate: hl.HandLandmarkerDelegate.gpu,
  );

  @override
  ImageFormatGroup get imageFormat => ImageFormatGroup.yuv420;

  @override
  Stream<List<Hand>> get hands => _plugin.landmarkStream.map(
    (found) => [
      for (final h in found) [for (final l in h.landmarks) Pt(l.x, l.y, l.z)],
    ],
  );

  @override
  void process(CameraImage image, int sensorOrientation) {
    try {
      _plugin.processFrame(image, sensorOrientation);
    } catch (e) {
      debugPrint('[PalmTunes] Hand tracking frame failed -> $e');
    }
  }

  @override
  Future<void> dispose() async {
    try {
      _plugin.dispose();
    } catch (_) {}
  }
}

/// iOS: the same MediaPipe model through ios/Runner/HandTrackerPlugin.swift.
/// Frames go over a method channel; the answer is a flat list of
/// x, y, z triples per hand (63 numbers).
class IosHandTracker implements HandTracker {
  static const MethodChannel _channel = MethodChannel('palmtunes/hands');
  final StreamController<List<Hand>> _out =
      StreamController<List<Hand>>.broadcast();
  bool _busy = false;
  int _lastFrameMs = 0;

  @override
  ImageFormatGroup get imageFormat => ImageFormatGroup.bgra8888;

  @override
  Stream<List<Hand>> get hands => _out.stream;

  @override
  void process(CameraImage image, int sensorOrientation) {
    if (_busy || _out.isClosed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFrameMs < 66) return; // ~15 frames per second is plenty
    _lastFrameMs = now;
    _busy = true;
    final plane = image.planes.first;
    () async {
      try {
        final result = await _channel.invokeMethod<List<Object?>>('detect', {
          'bytes': plane.bytes,
          'width': image.width,
          'height': image.height,
          'bytesPerRow': plane.bytesPerRow,
          'rotation': sensorOrientation,
        });
        if (_out.isClosed) return;
        final found = <Hand>[];
        for (final item in result ?? const []) {
          final flat = (item as List).cast<num>();
          if (flat.length < 63) continue;
          found.add([
            for (var i = 0; i < 21; i++)
              Pt(
                flat[i * 3].toDouble(),
                flat[i * 3 + 1].toDouble(),
                flat[i * 3 + 2].toDouble(),
              ),
          ]);
        }
        _out.add(found);
      } catch (e) {
        debugPrint('[PalmTunes] iOS hand tracking failed -> $e');
      } finally {
        _busy = false;
      }
    }();
  }

  @override
  Future<void> dispose() async {
    await _out.close();
    try {
      await _channel.invokeMethod('close');
    } catch (_) {}
  }
}
