import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
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

// ===========================================================================
// Frame preview used while dragging the seek bar
// ===========================================================================

/// A second, silent player that shows the picture at the spot the finger is
/// on while the seek bar is dragged. Only created when a song is scrubbed.
class ScrubPreview {
  final PlayerHub hub;
  ScrubPreview(this.hub);

  Player? _player;
  VideoController? controller;
  String? _openedUri;
  final ValueNotifier<bool> ready = ValueNotifier<bool>(false);
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  bool get hasVideo => (hub.player.state.width ?? 0) > 0;

  Future<void> prepare() async {
    if (!hasVideo) return;
    final media = hub.currentMedia;
    if (media == null) return;
    if (_player != null && _openedUri == media.uri) return;
    ready.value = false;
    _player ??= Player(
      configuration: const PlayerConfiguration(bufferSize: 16 * 1024 * 1024),
    );
    controller ??= VideoController(_player!);
    _openedUri = media.uri;
    try {
      await _player!.setVolume(0);
      await _player!.open(media, play: false);
      ready.value = true;
    } catch (e) {
      debugPrint('[PalmTunes] Seek preview could not open -> $e');
    }
  }

  void seek(Duration position) {
    final player = _player;
    if (player == null || !ready.value) return;
    final now = DateTime.now();
    if (now.difference(_lastSeek).inMilliseconds < 80) return;
    _lastSeek = now;
    player.seek(position);
  }

  void dispose() {
    _player?.dispose();
    _player = null;
    controller = null;
    ready.dispose();
  }
}

// ===========================================================================
// Screen
// ===========================================================================

class VideoPlayerScreen extends StatefulWidget {
  const VideoPlayerScreen({super.key});

  static Future<void> open(BuildContext context) async {
    final hub = context.read<PlayerHub>();
    if (hub.isPlayerOpen || hub.current == null) return;
    hub.setPlayerOpen(true);
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
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

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with SingleTickerProviderStateMixin {
  static const Duration _hideDelay = Duration(seconds: 3);

  late final PlayerHub _hub = context.read<PlayerHub>();
  late final SettingsStore _settings = context.read<SettingsStore>();
  late final ScrubPreview _preview = ScrubPreview(_hub);

  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _panelOpen = false;

  _SeekBubble? _bubble;
  Timer? _bubbleTimer;
  _HoldMode _hold = _HoldMode.none;
  double _rateBeforeHold = 1;
  bool _wasPlayingBeforeReverse = false;
  Duration _reversePos = Duration.zero;
  Timer? _reverseTimer;
  Offset _lastDoubleTap = Offset.zero;
  bool _popping = false;

  // Swipe-down-to-close
  double _dragDy = 0;
  double _snapFrom = 0;
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void initState() {
    super.initState();
    _snap.addListener(() {
      setState(
        () => _dragDy = _snapFrom * (1 - Curves.easeOut.transform(_snap.value)),
      );
    });
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
    _snap.dispose();
    _preview.dispose();
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

  // ---- fullscreen controls visibility ---------------------------------------

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
          !_panelOpen &&
          _hold == _HoldMode.none) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _onTap() {
    if (_panelOpen) {
      setState(() => _panelOpen = false);
      return;
    }
    if (_hub.isFullscreen) {
      if (_controlsVisible) {
        _hideTimer?.cancel();
        setState(() => _controlsVisible = false);
      } else {
        _showControls();
      }
    } else {
      _hub.togglePlay();
    }
  }

  // ---- seeking and holding on the picture ------------------------------------

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

  // ---- swipe down to close ------------------------------------------------------

  void _dismissStart(DragStartDetails _) => _snap.stop();

  void _dismissUpdate(DragUpdateDetails d) {
    if (_hub.isFullscreen) return;
    setState(() => _dragDy = math.max(0.0, _dragDy + d.delta.dy));
  }

  void _dismissEnd(DragEndDetails d) {
    if (_hub.isFullscreen) return;
    final v = d.primaryVelocity ?? 0;
    if (_dragDy > 130 || v > 800) {
      Navigator.of(context).maybePop();
    } else {
      _snapFrom = _dragDy;
      _snap.forward(from: 0);
    }
  }

  // ---- build -------------------------------------------------------------------------

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
      child: Transform.translate(
        offset: Offset(0, full ? 0 : _dragDy),
        child: Scaffold(
          backgroundColor: AppColors.background,
          body: item == null
              ? const SizedBox.shrink()
              : full
              ? _fullscreen(hub, item)
              : _portrait(hub, item),
        ),
      ),
    );
  }

  // ---- portrait -----------------------------------------------------------------------

  Widget _portrait(PlayerHub hub, PlayItem item) {
    final accent = Theme.of(context).colorScheme.primary;
    final meter = context.read<BassMeter>();
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
              // The top bar and the picture stay put; dragging them down closes
              // the player.
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragStart: _dismissStart,
                onVerticalDragUpdate: _dismissUpdate,
                onVerticalDragEnd: _dismissEnd,
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
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: _surface(hub, item),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Everything below scrolls underneath the picture.
              Expanded(
                child: ListView(
                  physics: const ClampingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(0, 8, 0, 30),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22),
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
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _SeekBar(
                      hub: hub,
                      preview: _preview,
                      horizontalPadding: 14,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 22),
                      child: _controls(hub),
                    ),
                    const SizedBox(height: 18),
                    ..._upNextWidgets(context, hub, afterPick: null),
                  ],
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
          onPressed: hub.toggleMute,
          icon: Icon(
            hub.isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          ),
          color: hub.isMuted ? accent : Colors.white70,
        ),
      ],
    );
  }

  // ---- fullscreen (landscape) -------------------------------------------------------

  Widget _fullscreen(PlayerHub hub, PlayItem item) {
    final width = MediaQuery.sizeOf(context).width;
    final panelW = math.min(380.0, width * 0.5);
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
                // Must not catch taps, or tapping again could not hide the UI.
                const IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
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
                ),
                SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 60, 0),
                        child: Row(
                          children: [
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
                          ],
                        ),
                      ),
                      const Spacer(),
                      _SeekBar(
                        hub: hub,
                        preview: _preview,
                        horizontalPadding: 20,
                        onInteract: _showControls,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                        child: Row(
                          children: [
                            const SizedBox(width: 96),
                            Expanded(
                              child: Row(
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
                                    icon: const Icon(
                                      Icons.skip_next_rounded,
                                      size: 34,
                                    ),
                                    color: Colors.white,
                                    disabledColor: Colors.white24,
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                              width: 96,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  IconButton(
                                    onPressed: hub.toggleMute,
                                    icon: Icon(
                                      hub.isMuted
                                          ? Icons.volume_off_rounded
                                          : Icons.volume_up_rounded,
                                    ),
                                    color: Colors.white,
                                  ),
                                  IconButton(
                                    onPressed: _close,
                                    icon: const Icon(
                                      Icons.fullscreen_exit_rounded,
                                      size: 28,
                                    ),
                                    color: Colors.white,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // The arrow on the right edge that brings in the Up next panel.
                if (!_panelOpen)
                  Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _panelOpen = true;
                        _hideTimer?.cancel();
                      }),
                      child: Container(
                        width: 34,
                        height: 76,
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.horizontal(
                            left: Radius.circular(18),
                          ),
                        ),
                        child: const Icon(
                          Icons.chevron_left_rounded,
                          color: Colors.white,
                          size: 30,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_panelOpen)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _panelOpen = false),
              child: const ColoredBox(color: Colors.black38),
            ),
          ),
        AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: 0,
          right: _panelOpen ? 0 : -panelW - 20,
          width: panelW,
          child: IgnorePointer(
            ignoring: !_panelOpen,
            child: _SidePanel(
              hub: hub,
              onClose: () => setState(() => _panelOpen = false),
              children: _upNextWidgets(
                context,
                hub,
                afterPick: () => setState(() => _panelOpen = false),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---- the picture, with all the touch gestures ---------------------------------

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
              if (!hub.isFullscreen)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: IconButton(
                    onPressed: hub.toggleFullscreen,
                    icon: const Icon(Icons.fullscreen_rounded, size: 28),
                    color: Colors.white,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black38,
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

// ===========================================================================
// Up next / Recommended (inline in portrait, in the side panel in fullscreen)
// ===========================================================================

List<Widget> _upNextWidgets(
  BuildContext context,
  PlayerHub hub, {
  required VoidCallback? afterPick,
}) {
  final accent = Theme.of(context).colorScheme.primary;
  final queue = hub.queue;
  final upcoming = <int>[
    for (var i = math.max(0, hub.index + 1); i < queue.length; i++) i,
  ];
  final recs = hub.autoRecommend ? hub.recommendations : <YtVideo>[];

  Widget header(String text, {bool loading = false}) => Padding(
    padding: const EdgeInsets.fromLTRB(22, 14, 22, 6),
    child: Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 16.5,
          ),
        ),
        const SizedBox(width: 10),
        if (loading)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    ),
  );

  final out = <Widget>[];
  if (upcoming.isNotEmpty) {
    out.add(header('Up next'));
    for (final i in upcoming) {
      out.add(
        _QueueRow(
          title: queue[i].title,
          subtitle: queue[i].author,
          thumb: queue[i].thumbnailUrl,
          current: false,
          accent: accent,
          onTap: () {
            hub.playQueueIndex(i);
            afterPick?.call();
          },
        ),
      );
    }
  }
  if (hub.autoRecommend) {
    out.add(header('Recommended', loading: hub.recommendationsLoading));
    if (recs.isEmpty && !hub.recommendationsLoading) {
      out.add(
        const Padding(
          padding: EdgeInsets.fromLTRB(22, 4, 22, 4),
          child: Text(
            'No recommendations yet',
            style: TextStyle(color: Colors.white38),
          ),
        ),
      );
    }
    for (final v in recs) {
      out.add(
        _QueueRow(
          title: v.title,
          subtitle: v.author,
          thumb: v.thumbnailUrl,
          current: false,
          accent: accent,
          onTap: () {
            hub.playRecommendation(v);
            afterPick?.call();
          },
          trailing: DownloadButton(video: v, size: 40),
        ),
      );
    }
  }
  if (out.isEmpty) {
    out.add(
      const Padding(
        padding: EdgeInsets.fromLTRB(22, 18, 22, 4),
        child: Text(
          'Nothing queued after this song',
          style: TextStyle(color: Colors.white38),
        ),
      ),
    );
  }
  return out;
}

class _SidePanel extends StatelessWidget {
  final PlayerHub hub;
  final VoidCallback onClose;
  final List<Widget> children;

  const _SidePanel({
    required this.hub,
    required this.onClose,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2100A0C),
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 6, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Up next',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.chevron_right_rounded, size: 30),
                    color: Colors.white,
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 20),
                children: children,
              ),
            ),
          ],
        ),
      ),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(9),
              child: SizedBox(
                width: 88,
                height: 50,
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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: current ? accent : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Small widgets
// ===========================================================================

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

// ===========================================================================
// Seek bar: drag to scrub, slide up to zoom the preview, slide down onto the
// X to cancel
// ===========================================================================

class _ScrubState {
  final double frac;
  final Duration pos;
  final Duration total;
  final double zoom;
  final bool overX;
  final bool commit;
  final bool popping;
  final Rect geom;

  const _ScrubState({
    required this.frac,
    required this.pos,
    required this.total,
    required this.zoom,
    required this.overX,
    required this.commit,
    required this.popping,
    required this.geom,
  });

  _ScrubState copyWith({
    double? zoom,
    bool? commit,
    bool? popping,
    bool? overX,
  }) => _ScrubState(
    frac: frac,
    pos: pos,
    total: total,
    zoom: zoom ?? this.zoom,
    overX: overX ?? this.overX,
    commit: commit ?? this.commit,
    popping: popping ?? this.popping,
    geom: geom,
  );
}

class _SeekBar extends StatefulWidget {
  final PlayerHub hub;
  final ScrubPreview preview;
  final VoidCallback? onInteract;
  final double horizontalPadding;

  const _SeekBar({
    required this.hub,
    required this.preview,
    this.onInteract,
    this.horizontalPadding = 16,
  });

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  static const double _trackHeight = 7;
  static const double _hitHeight = 46;
  static const double _moveSlop = 8;

  final GlobalKey _barKey = GlobalKey();
  ValueNotifier<_ScrubState>? _state;
  OverlayEntry? _entry;

  Duration _total = Duration.zero;
  double _liveFrac = 0;
  Offset _startGlobal = Offset.zero;
  Rect _geom = Rect.zero;
  bool _down = false;
  bool _scrubbing = false;
  double _frac = 0;

  @override
  void dispose() {
    _closeOverlay();
    super.dispose();
  }

  double _fracFor(double globalX) {
    if (_geom.width <= 0) return 0;
    return ((globalX - _geom.left) / _geom.width).clamp(0.0, 1.0);
  }

  Duration _posFor(double frac) =>
      Duration(milliseconds: (frac * _total.inMilliseconds).round());

  void _onDown(PointerDownEvent e) {
    final box = _barKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _total <= Duration.zero) return;
    final topLeft = box.localToGlobal(Offset.zero);
    _geom = Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      box.size.width,
      box.size.height,
    );
    _startGlobal = e.position;
    _down = true;
    _scrubbing = false;
    _frac = _fracFor(e.position.dx);
    widget.onInteract?.call();
  }

  void _onMove(PointerMoveEvent e) {
    if (!_down) return;
    if (!_scrubbing) {
      if ((e.position - _startGlobal).distance < _moveSlop) return;
      _scrubbing = true;
      widget.preview.prepare();
      _showOverlay();
    }
    _frac = _fracFor(e.position.dx);
    final dy = e.position.dy - _startGlobal.dy;
    final zoom = dy < -24 ? ((-dy - 24) / 220).clamp(0.0, 1.0) : 0.0;
    final overX = dy > 46;
    final pos = _posFor(_frac);
    final current = _state!.value;
    _state!.value = _ScrubState(
      frac: _frac,
      pos: pos,
      total: _total,
      zoom: zoom,
      overX: overX,
      commit: false,
      popping: current.popping,
      geom: _geom,
    );
    widget.preview.seek(pos);
    setState(() => _liveFrac = _frac);
    widget.onInteract?.call();
  }

  Future<void> _onUp(PointerUpEvent e) async {
    if (!_down) return;
    _down = false;
    final hub = widget.hub;
    if (!_scrubbing) {
      // A plain tap: jump there.
      hub.player.seek(_posFor(_fracFor(e.position.dx)));
      return;
    }
    _scrubbing = false;
    final s = _state!.value;
    if (s.overX) {
      // Cancel: pop the X like a bubble and leave playback where it was.
      _state!.value = s.copyWith(popping: true);
      await Future<void>.delayed(const Duration(milliseconds: 230));
      _closeOverlay();
    } else if (s.zoom >= 0.45) {
      // Zoom the preview up to the full screen, then carry on from there.
      _state!.value = s.copyWith(zoom: 1, commit: true);
      await Future<void>.delayed(const Duration(milliseconds: 320));
      hub.player.seek(s.pos);
      if (!hub.isPlaying) hub.play();
      _closeOverlay();
    } else {
      hub.player.seek(s.pos);
      _closeOverlay();
    }
    if (mounted) setState(() {});
  }

  void _onCancel(PointerCancelEvent e) {
    _down = false;
    _scrubbing = false;
    _closeOverlay();
    if (mounted) setState(() {});
  }

  void _showOverlay() {
    final accent = Theme.of(context).colorScheme.primary;
    final item = widget.hub.current;
    _state = ValueNotifier<_ScrubState>(
      _ScrubState(
        frac: _frac,
        pos: _posFor(_frac),
        total: _total,
        zoom: 0,
        overX: false,
        commit: false,
        popping: false,
        geom: _geom,
      ),
    );
    _entry = OverlayEntry(
      builder: (_) => _ScrubOverlay(
        state: _state!,
        preview: widget.preview,
        thumb: item?.thumbnailUrl ?? '',
        accent: accent,
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void _closeOverlay() {
    _entry?.remove();
    _entry = null;
    _state?.dispose();
    _state = null;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final player = widget.hub.player;
    return StreamBuilder<Duration>(
      stream: player.stream.duration,
      initialData: player.state.duration,
      builder: (context, durSnap) {
        _total = durSnap.data ?? Duration.zero;
        final totalMs = _total.inMilliseconds;
        return StreamBuilder<Duration>(
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, posSnap) {
            final posMs = (posSnap.data ?? Duration.zero).inMilliseconds;
            final live = totalMs <= 0 ? 0.0 : (posMs / totalMs).clamp(0.0, 1.0);
            final frac = _scrubbing ? _liveFrac : live;
            final shownPos = _scrubbing
                ? _posFor(frac)
                : (posSnap.data ?? Duration.zero);
            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: widget.horizontalPadding,
              ),
              child: Column(
                children: [
                  // Eager recogniser: while a finger is on the bar the list
                  // behind it must not start scrolling.
                  RawGestureDetector(
                    gestures: {
                      EagerGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                            EagerGestureRecognizer
                          >(() => EagerGestureRecognizer(), (_) {}),
                    },
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onDown,
                      onPointerMove: _onMove,
                      onPointerUp: _onUp,
                      onPointerCancel: _onCancel,
                      child: SizedBox(
                        key: _barKey,
                        height: _hitHeight,
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final w = c.maxWidth;
                            final thumbR = _scrubbing ? 11.0 : 8.0;
                            return Stack(
                              alignment: Alignment.centerLeft,
                              clipBehavior: Clip.none,
                              children: [
                                Container(
                                  height: _trackHeight,
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(
                                      _trackHeight,
                                    ),
                                  ),
                                ),
                                Container(
                                  height: _trackHeight,
                                  width: w * frac,
                                  decoration: BoxDecoration(
                                    color: accent,
                                    borderRadius: BorderRadius.circular(
                                      _trackHeight,
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: (w * frac - thumbR).clamp(
                                    -thumbR,
                                    w - thumbR,
                                  ),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 120),
                                    width: thumbR * 2,
                                    height: thumbR * 2,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.white,
                                      boxShadow: [
                                        BoxShadow(
                                          color: accent.withValues(alpha: 0.6),
                                          blurRadius: _scrubbing ? 12 : 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          formatDuration(shownPos),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                          ),
                        ),
                        Text(
                          formatDuration(_total),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _ScrubOverlay extends StatelessWidget {
  final ValueNotifier<_ScrubState> state;
  final ScrubPreview preview;
  final String thumb;
  final Color accent;

  const _ScrubOverlay({
    required this.state,
    required this.preview,
    required this.thumb,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ValueListenableBuilder<_ScrubState>(
        valueListenable: state,
        builder: (context, s, _) {
          final size = MediaQuery.sizeOf(context);
          const w = 190.0;
          const h = 107.0;
          final thumbX = (s.geom.left + s.frac * s.geom.width).clamp(
            w / 2 + 12,
            size.width - w / 2 - 12,
          );
          final small = Rect.fromLTWH(
            thumbX - w / 2,
            math.max(12.0, s.geom.top - 26 - h),
            w,
            h,
          );
          final full = Offset.zero & size;
          final dur = s.commit
              ? const Duration(milliseconds: 300)
              : Duration.zero;

          return Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: s.zoom * 0.75),
                    duration: dur,
                    builder: (_, v, _) =>
                        ColoredBox(color: Colors.black.withValues(alpha: v)),
                  ),
                ),
              ),
              TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  end: Curves.easeOutCubic.transform(s.zoom),
                ),
                duration: dur,
                curve: Curves.easeOutCubic,
                builder: (context, z, _) {
                  final rect = Rect.lerp(small, full, z)!;
                  return Positioned.fromRect(
                    rect: rect,
                    child: _previewBox(s, 14 * (1 - z), z),
                  );
                },
              ),
              // The X below the thumb: pops in, grows when the finger is on it
              // and bursts when the finger lets go there.
              Positioned(
                left: (s.geom.left + s.frac * s.geom.width - 28).clamp(
                  8.0,
                  size.width - 64,
                ),
                top: math.min(s.geom.bottom + 34, size.height - 86),
                child: IgnorePointer(child: _xBubble(s)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _previewBox(_ScrubState s, double radius, double z) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          border: Border.all(color: accent.withValues(alpha: 1 - z), width: 2),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ThumbImage(source: thumb),
            if (preview.hasVideo)
              ValueListenableBuilder<bool>(
                valueListenable: preview.ready,
                builder: (_, ready, _) {
                  final c = preview.controller;
                  if (!ready || c == null) return const SizedBox.shrink();
                  return Video(
                    controller: c,
                    controls: NoVideoControls,
                    fill: Colors.black,
                  );
                },
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${formatDuration(s.pos)} / ${formatDuration(s.total)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _xBubble(_ScrubState s) {
    final hidden = s.zoom > 0.05;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.elasticOut,
      builder: (context, appear, _) {
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: s.popping ? 1.9 : (s.overX ? 1.28 : 1.0)),
          duration: Duration(milliseconds: s.popping ? 200 : 150),
          curve: Curves.easeOut,
          builder: (context, grow, _) {
            return Opacity(
              opacity: hidden ? 0 : 1,
              child: AnimatedOpacity(
                opacity: s.popping ? 0 : 1,
                duration: const Duration(milliseconds: 200),
                child: Transform.scale(
                  scale: appear * grow,
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: s.overX
                          ? Colors.redAccent.shade200
                          : Colors.black.withValues(alpha: 0.7),
                      border: Border.all(
                        color: s.overX ? Colors.white : Colors.white38,
                        width: 2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.redAccent.withValues(
                            alpha: s.overX ? 0.55 : 0,
                          ),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
