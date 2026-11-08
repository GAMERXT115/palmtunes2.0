import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'bass_meter.dart';
import 'player_hub.dart';
import 'search.dart';
import 'settings.dart';
import 'ui.dart';

enum _HoldMode { none, forward, reverse }

class _SeekBubble {
  final bool forward;
  final int seconds;
  const _SeekBubble(this.forward, this.seconds);
}

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key});

  static Future<void> open(BuildContext context) async {
    final hub = context.read<PlayerHub>();
    if (hub.isPlayerOpen || hub.current == null) return;
    hub.setPlayerOpen(true);
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, _, _) => const VideoPlayerScreen(),
        transitionsBuilder: (_, a, _, child) {
          final curved = CurvedAnimation(
            parent: a,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
      ),
    );
    await hub.setFullscreen(false);
    hub.setPlayerOpen(false);
  }

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  static const Duration _hideDelay = Duration(seconds: 3);

  late final PlayerHub _hub = context.read<PlayerHub>();
  late final SettingsStore _settings = context.read<SettingsStore>();

  bool _controlsVisible = true;
  Timer? _hideTimer;

  _SeekBubble? _bubble;
  Timer? _bubbleTimer;
  _HoldMode _hold = _HoldMode.none;
  double _rateBeforeHold = 1;
  bool _wasPlayingBeforeReverse = false;
  Duration _reversePos = Duration.zero;
  Timer? _reverseTimer;
  Offset _lastDoubleTap = Offset.zero;
  bool _popping = false;

  @override
  void initState() {
    super.initState();
    _hub.addListener(_onHub);
    _onHub();
    _scheduleHide();
  }

  @override
  void dispose() {
    _hub.removeListener(_onHub);
    _hideTimer?.cancel();
    _bubbleTimer?.cancel();
    _reverseTimer?.cancel();
    if (_hold == _HoldMode.forward) _hub.player.setRate(_rateBeforeHold);
    WakelockPlus.disable();
    super.dispose();
  }

  void _onHub() {
    WakelockPlus.toggle(enable: _hub.isPlaying);
    if (_hub.current == null && !_popping && mounted) {
      _popping = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_hideDelay, () {
      if (mounted &&
          _hub.isFullscreen &&
          _hub.isPlaying &&
          _hold == _HoldMode.none) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onTap() {
    if (_hub.isFullscreen) {
      if (_controlsVisible) {
        setState(() => _controlsVisible = false);
      } else {
        _showControls();
      }
    } else {
      _hub.togglePlay();
    }
  }

  void _seekWithBubble(bool forward) {
    final secs = _settings.seekSeconds;
    _hub.seekBy(Duration(seconds: forward ? secs : -secs));
    setState(() {
      final b = _bubble;
      _bubble = b != null && b.forward == forward
          ? _SeekBubble(forward, b.seconds + secs)
          : _SeekBubble(forward, secs);
    });
    _bubbleTimer?.cancel();
    _bubbleTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _bubble = null);
    });
  }

  void _onDoubleTap(double width) {
    final third = width / 3;
    if (_lastDoubleTap.dx < third) {
      _seekWithBubble(false);
    } else if (_lastDoubleTap.dx > third * 2) {
      _seekWithBubble(true);
    } else {
      _hub.toggleFullscreen();
    }
  }

  void _startHold(bool forward) {
    if (_hold != _HoldMode.none) return;
    final speed = _settings.holdSpeed;
    if (forward) {
      _rateBeforeHold = _hub.player.state.rate;
      _hub.player.setRate(speed);
      if (!_hub.isPlaying) _hub.player.play();
      setState(() => _hold = _HoldMode.forward);
      return;
    }
    // Phones have no ffmpeg to play the sound backwards, so rewinding scrubs
    // the picture back silently.
    _wasPlayingBeforeReverse = _hub.isPlaying;
    _reversePos = _hub.player.state.position;
    _hub.player.pause();
    const tick = Duration(milliseconds: 120);
    final step = Duration(milliseconds: (tick.inMilliseconds * speed).round());
    _reverseTimer = Timer.periodic(tick, (_) {
      _reversePos -= step;
      if (_reversePos <= Duration.zero) {
        _reversePos = Duration.zero;
        _hub.player.seek(Duration.zero);
        _stopHold();
        return;
      }
      _hub.player.seek(_reversePos);
    });
    setState(() => _hold = _HoldMode.reverse);
  }

  void _stopHold() {
    if (_hold == _HoldMode.none) return;
    if (_hold == _HoldMode.forward) {
      _hub.player.setRate(_rateBeforeHold);
    } else {
      _reverseTimer?.cancel();
      _reverseTimer = null;
      if (_wasPlayingBeforeReverse) _hub.player.play();
    }
    if (mounted) setState(() => _hold = _HoldMode.none);
  }

  Future<void> _close() async {
    if (_hub.isFullscreen) {
      await _hub.setFullscreen(false);
      return;
    }
    if (mounted) Navigator.of(context).maybePop();
  }

  void _openQueue() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _QueueSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<PlayerHub>();
    final item = hub.current;
    final full = hub.isFullscreen;
    return PopScope(
      canPop: !full,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && full) hub.setFullscreen(false);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: item == null
            ? const SizedBox.shrink()
            : full
            ? _fullscreen(hub, item)
            : _portrait(hub, item),
      ),
    );
  }

  // ---- portrait -------------------------------------------------------------

  Widget _portrait(PlayerHub hub, PlayItem item) {
    final accent = Theme.of(context).colorScheme.primary;
    final meter = context.read<BassMeter>();
    final muted = hub.isMuted || hub.volume == 0;
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [accent.withValues(alpha: 0.22), AppColors.background],
                stops: const [0, 0.55],
              ),
            ),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _close,
                      icon: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 32,
                      ),
                      color: Colors.white,
                    ),
                    const Expanded(
                      child: Text(
                        'Now Playing',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white70,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: item.localPath == null
                          ? DownloadButton(
                              video: YtVideo(
                                id: item.videoId,
                                title: item.title,
                                author: item.author,
                                duration: item.duration,
                                thumbnailUrl: item.thumbnailUrl,
                              ),
                              size: 48,
                            )
                          : const Icon(
                              Icons.download_done_rounded,
                              color: AppColors.success,
                            ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: _surface(hub, item),
                  ),
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Center(
                        child: BassBars(
                          level: meter.level,
                          color: accent,
                          bars: 30,
                          height: 54,
                          barWidth: 6,
                          gap: 4,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _SeekBar(hub: hub),
                      const SizedBox(height: 4),
                      _controls(hub),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          IconButton(
                            onPressed: hub.toggleMute,
                            icon: Icon(
                              muted
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                            ),
                            color: Colors.white70,
                          ),
                          Expanded(
                            child: Slider(
                              value: hub.isMuted ? 0 : hub.volume,
                              min: 0,
                              max: 100,
                              onChanged: hub.setVolumeLevel,
                            ),
                          ),
                          IconButton(
                            onPressed: () => hub.toggleFullscreen(),
                            icon: const Icon(
                              Icons.fullscreen_rounded,
                              size: 28,
                            ),
                            color: Colors.white70,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _controls(PlayerHub hub) {
    final accent = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        IconButton(
          onPressed: hub.toggleShuffle,
          icon: const Icon(Icons.shuffle_rounded),
          color: hub.shuffle ? accent : Colors.white54,
        ),
        IconButton(
          onPressed: hub.previous,
          icon: const Icon(Icons.skip_previous_rounded, size: 40),
          color: Colors.white,
        ),
        _PlayButton(hub: hub, size: 70),
        IconButton(
          onPressed: hub.hasNext ? hub.next : null,
          icon: const Icon(Icons.skip_next_rounded, size: 40),
          color: Colors.white,
          disabledColor: Colors.white24,
        ),
        IconButton(
          onPressed: _openQueue,
          icon: const Icon(Icons.queue_music_rounded),
          color: Colors.white70,
        ),
      ],
    );
  }

  // ---- fullscreen (landscape) ----------------------------------------------

  Widget _fullscreen(PlayerHub hub, PlayItem item) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _surface(hub, item),
        IgnorePointer(
          ignoring: !_controlsVisible,
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black87,
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black87,
                      ],
                      stops: [0, 0.3, 0.6, 1],
                    ),
                  ),
                ),
                SafeArea(
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            onPressed: _close,
                            icon: const Icon(
                              Icons.fullscreen_exit_rounded,
                              size: 28,
                            ),
                            color: Colors.white,
                          ),
                          Expanded(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _openQueue,
                            icon: const Icon(Icons.queue_music_rounded),
                            color: Colors.white,
                          ),
                        ],
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: _SeekBar(hub: hub, onInteract: _showControls),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            onPressed: hub.previous,
                            icon: const Icon(
                              Icons.skip_previous_rounded,
                              size: 34,
                            ),
                            color: Colors.white,
                          ),
                          const SizedBox(width: 18),
                          _PlayButton(hub: hub, size: 54),
                          const SizedBox(width: 18),
                          IconButton(
                            onPressed: hub.hasNext ? hub.next : null,
                            icon: const Icon(Icons.skip_next_rounded, size: 34),
                            color: Colors.white,
                            disabledColor: Colors.white24,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---- the picture, with all the touch gestures -----------------------------

  Widget _surface(PlayerHub hub, PlayItem item) {
    final player = hub.player;
    return LayoutBuilder(
      builder: (context, c) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          onDoubleTapDown: (d) => _lastDoubleTap = d.localPosition,
          onDoubleTap: () => _onDoubleTap(c.maxWidth),
          onLongPressStart: (d) =>
              _startHold(d.localPosition.dx > c.maxWidth / 2),
          onLongPressEnd: (_) => _stopHold(),
          onLongPressCancel: _stopHold,
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              StreamBuilder<int?>(
                stream: player.stream.width,
                initialData: player.state.width,
                builder: (context, snap) {
                  final hasVideo = (snap.data ?? 0) > 0;
                  if (!hasVideo) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ThumbImage(source: item.thumbnailUrl),
                        const ColoredBox(color: Colors.black26),
                      ],
                    );
                  }
                  return CrossfadeVideo(hub: hub);
                },
              ),
              if (hub.isLoading)
                const Center(
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              if (hub.error != null && !hub.isLoading)
                Container(
                  color: Colors.black87,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: Colors.white70,
                        size: 30,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        hub.error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: hub.retryCurrent,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Try again'),
                      ),
                    ],
                  ),
                ),
              if (_hold != _HoldMode.none)
                Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _Pill(
                      icon: _hold == _HoldMode.forward
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      text:
                          '${_settings.holdSpeed.toStringAsFixed(_settings.holdSpeed % 1 == 0 ? 0 : 1)}x',
                    ),
                  ),
                ),
              if (_bubble != null)
                Align(
                  alignment: _bubble!.forward
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: _Pill(
                      icon: _bubble!.forward
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      text: '${_bubble!.seconds}s',
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Pill({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final PlayerHub hub;
  final double size;
  const _PlayButton({required this.hub, required this.size});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: hub.togglePlay,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: accent,
          boxShadow: [
            BoxShadow(color: accent.withValues(alpha: 0.45), blurRadius: 18),
          ],
        ),
        child: hub.isLoading
            ? Padding(
                padding: EdgeInsets.all(size * 0.28),
                child: const CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.white,
                ),
              )
            : Icon(
                hub.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: Colors.white,
                size: size * 0.56,
              ),
      ),
    );
  }
}

class _SeekBar extends StatefulWidget {
  final PlayerHub hub;
  final VoidCallback? onInteract;
  const _SeekBar({required this.hub, this.onInteract});

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final player = widget.hub.player;
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration.zero;
        final maxMs = dur.inMilliseconds.toDouble();
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final posMs = pos.inMilliseconds.toDouble();
            final shown = (_drag ?? posMs).clamp(0.0, maxMs <= 0 ? 1.0 : maxMs);
            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 4,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 7,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 16,
                    ),
                  ),
                  child: Slider(
                    value: shown,
                    min: 0,
                    max: maxMs <= 0 ? 1.0 : maxMs,
                    onChangeStart: (v) {
                      widget.onInteract?.call();
                      setState(() => _drag = v);
                    },
                    onChanged: maxMs <= 0
                        ? null
                        : (v) {
                            widget.onInteract?.call();
                            setState(() => _drag = v);
                          },
                    onChangeEnd: (v) {
                      player.seek(Duration(milliseconds: v.round()));
                      setState(() => _drag = null);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDuration(Duration(milliseconds: shown.round())),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        formatDuration(dur),
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _QueueSheet extends StatelessWidget {
  const _QueueSheet();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return DraggableScrollableSheet(
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scroll) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: GlassContainer(
            borderRadius: 24,
            opacity: 0.14,
            child: Consumer<PlayerHub>(
              builder: (context, hub, _) {
                final queue = hub.queue;
                final recs = hub.autoRecommend
                    ? hub.recommendations
                    : <YtVideo>[];
                return ListView(
                  controller: scroll,
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
                  children: [
                    Center(
                      child: Container(
                        width: 38,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      'Up next',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < queue.length; i++)
                      _QueueRow(
                        title: queue[i].title,
                        subtitle: queue[i].author,
                        thumb: queue[i].thumbnailUrl,
                        current: i == hub.index,
                        accent: accent,
                        onTap: () => hub.playQueueIndex(i),
                      ),
                    if (hub.autoRecommend) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text(
                            'Recommended',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (hub.recommendationsLoading)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (recs.isEmpty && !hub.recommendationsLoading)
                        const Text(
                          'No recommendations yet',
                          style: TextStyle(color: Colors.white38),
                        ),
                      for (final v in recs)
                        _QueueRow(
                          title: v.title,
                          subtitle: v.author,
                          thumb: v.thumbnailUrl,
                          current: false,
                          accent: accent,
                          onTap: () {
                            hub.playRecommendation(v);
                            Navigator.pop(context);
                          },
                          trailing: DownloadButton(video: v, size: 40),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final String thumb;
  final bool current;
  final Color accent;
  final VoidCallback onTap;
  final Widget? trailing;

  const _QueueRow({
    required this.title,
    required this.subtitle,
    required this.thumb,
    required this.current,
    required this.accent,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 72,
                height: 42,
                child: ThumbImage(source: thumb),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current ? accent : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (current) Icon(Icons.equalizer_rounded, color: accent, size: 20),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
