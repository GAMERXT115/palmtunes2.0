import 'dart:async';

import 'package:audio_service/audio_service.dart';

import 'player_hub.dart';

/// Shows Palm Tunes on the lock screen / notification shade and routes the
/// buttons there (and on headphones or a car) back into the [PlayerHub].
class HubAudioHandler extends BaseAudioHandler with SeekHandler {
  final PlayerHub hub;
  Timer? _timer;
  String? _shownId;

  HubAudioHandler(this.hub) {
    hub.addListener(_sync);
    _timer = Timer.periodic(
      const Duration(milliseconds: 700),
      (_) => _pushState(),
    );
    _sync();
  }

  void _sync() {
    final item = hub.current;
    if (item?.videoId != _shownId) {
      _shownId = item?.videoId;
      if (item == null) {
        mediaItem.add(null);
      } else {
        final art = item.thumbnailUrl;
        mediaItem.add(
          MediaItem(
            id: item.videoId,
            title: item.title,
            artist: item.author,
            duration: item.duration,
            artUri: art.isEmpty
                ? null
                : (art.startsWith('http') ? Uri.parse(art) : Uri.file(art)),
          ),
        );
      }
    }
    _pushState();
  }

  void _pushState() {
    final has = hub.current != null;
    final playing = hub.isPlaying;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: !has
            ? AudioProcessingState.idle
            : hub.isLoading
            ? AudioProcessingState.loading
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: hub.player.state.position,
        bufferedPosition: hub.player.state.buffer,
        speed: hub.player.state.rate,
        queueIndex: hub.index < 0 ? null : hub.index,
      ),
    );
  }

  @override
  Future<void> play() => hub.play();

  @override
  Future<void> pause() => hub.pause();

  @override
  Future<void> skipToNext() => hub.next();

  @override
  Future<void> skipToPrevious() => hub.previous();

  @override
  Future<void> seek(Duration position) => hub.player.seek(position);

  @override
  Future<void> stop() async {
    await hub.close();
    _pushState();
  }

  Future<void> dispose() async {
    _timer?.cancel();
    hub.removeListener(_sync);
  }
}
