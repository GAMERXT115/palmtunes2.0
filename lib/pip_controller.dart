import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'player_hub.dart';
import 'settings.dart';

/// Native iPhone Picture in Picture for the video.
///
/// The video player (mpv) cannot hand its picture to iOS, so while the player
/// screen is open a second, silent AVPlayer plays the same video stream
/// behind the app (see PalmtunesHandsPlugin.swift). When you leave the app
/// iOS floats that picture in the Picture in Picture window while the sound
/// keeps coming from the normal player. Play/pause and "back to app" in the
/// small window are passed back here.
///
/// It only does anything on iPhone, only for songs that have a picture, and
/// only if "Picture in Picture" is on in Settings.
class PipController with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel('palmtunes/pip');

  final PlayerHub hub;
  final SettingsStore settings;
  PipController(this.hub, this.settings);

  bool _on = false;
  String? _preparedFor;
  Timer? _sync;

  bool get _enabled => Platform.isIOS && settings.pipEnabled;

  void start() {
    if (!Platform.isIOS || _on) return;
    _on = true;
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_onCall);
    hub.addListener(_onHub);
    _sync = Timer.periodic(const Duration(seconds: 2), (_) => _push());
    _onHub();
  }

  void dispose() {
    if (!_on) return;
    _on = false;
    WidgetsBinding.instance.removeObserver(this);
    hub.removeListener(_onHub);
    _sync?.cancel();
    _channel.setMethodCallHandler(null);
    _preparedFor = null;
    unawaited(_invoke('dispose'));
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (e) {
      debugPrint('[PalmTunes] PiP $method failed -> $e');
    }
  }

  void _onHub() {
    if (!_on) return;
    if (!_enabled) {
      if (_preparedFor != null) {
        _preparedFor = null;
        unawaited(_invoke('dispose'));
      }
      return;
    }
    final media = hub.currentMedia;
    final hasVideo = (hub.player.state.width ?? 0) > 0;
    if (media == null || !hasVideo || hub.isLoading) return;
    if (_preparedFor == media.uri) return;
    _preparedFor = media.uri;
    unawaited(
      _invoke('prepare', {
        'url': media.uri,
        'headers': media.httpHeaders ?? const <String, String>{},
        'positionMs': hub.player.state.position.inMilliseconds,
        'playing': hub.isPlaying,
      }),
    );
  }

  void _push() {
    if (!_on || _preparedFor == null) return;
    unawaited(
      _invoke('sync', {
        'positionMs': hub.player.state.position.inMilliseconds,
        'playing': hub.isPlaying,
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_on || _preparedFor == null) return;
    if (state == AppLifecycleState.inactive && hub.isPlaying) {
      _push();
      unawaited(_invoke('start'));
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? {};
    switch (call.method) {
      case 'pipPlaying':
        final playing = args['playing'] == true;
        if (playing && !hub.isPlaying) {
          unawaited(hub.play());
        } else if (!playing && hub.isPlaying) {
          unawaited(hub.pause());
        }
      case 'pipStopped':
        final ms = (args['positionMs'] as num?)?.toInt();
        final playing = args['playing'] == true;
        if (ms != null) {
          final diff = (hub.player.state.position.inMilliseconds - ms).abs();
          if (diff > 1500) unawaited(hub.player.seek(Duration(milliseconds: ms)));
        }
        if (playing && !hub.isPlaying) unawaited(hub.play());
        if (!playing && hub.isPlaying) unawaited(hub.pause());
    }
    return null;
  }
}
