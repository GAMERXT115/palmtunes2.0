import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'bass_meter.dart';
import 'pip_controller.dart';
import 'player_hub.dart';
import 'screen_gestures.dart';
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
  late final PipController _pip = PipController(_hub, _settings);

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
    _pip.start();
  }

  @override
  void dispose() {
    _hub.removeListener(_onHub);
    _hideTimer?.cancel();
    _bubbleTimer?.cancel();
    _reverseTimer?.cancel();
    _snap.dispose();
    _pip.dispose();
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
              Column(
                children: [
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
                    _SeekBar(hub: hub, item: item, horizontalPadding: 14),
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
                        item: item,
                        horizontalPadding: 20,
                        onDragStart: () {
                          _hideTimer?.cancel();
                          if (!_controlsVisible) {
                            setState(() => _controlsVisible = true);
                          }
                        },
                        onDragEnd: _scheduleHide,
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
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
                // Previous / play / next sit in the middle of the screen.
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: hub.previous,
                        icon: const Icon(Icons.skip_previous_rounded, size: 44),
                        color: Colors.white,
                      ),
                      const SizedBox(width: 26),
                      _PlayButton(hub: hub, size: 66),
                      const SizedBox(width: 26),
                      IconButton(
                        onPressed: hub.hasNext ? hub.next : null,
                        icon: const Icon(Icons.skip_next_rounded, size: 44),
                        color: Colors.white,
                        disabledColor: Colors.white24,
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
        return ScreenGestures(
          enabled: _hold == _HoldMode.none,
          onCircleStart: () =>
              Notch.show('Volume', icon: Icons.volume_up_rounded),
          onVolumeStep: (up) => hub.changeVolume(up ? 5 : -5),
          onNext: () {
            if (!hub.hasNext) return;
            Notch.show('Next', icon: Icons.skip_next_rounded);
            hub.next();
          },
          onPrevious: () {
            Notch.show('Previous', icon: Icons.skip_previous_rounded);
            hub.previous();
          },
          onPause: () {
            if (!hub.isPlaying) return;
            hub.pause();
            Notch.show('Paused', icon: Icons.pause_rounded);
          },
          onPlay: () {
            if (hub.isPlaying) return;
            hub.play();
            Notch.show('Playing', icon: Icons.play_arrow_rounded);
          },
          child: GestureDetector(
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
// Seek bar. Drag to scrub with a live picture above the thumb. Slide UP and
// the picture grows the higher you go; let go there and it zooms to full
// screen and plays from that spot. Slide DOWN onto the X and let go to cancel
// (the X bursts like a bubble).
// ===========================================================================

class _SeekBar extends StatefulWidget {
  final PlayerHub hub;
  final PlayItem item;
  final double horizontalPadding;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;

  const _SeekBar({
    required this.hub,
    required this.item,
    this.horizontalPadding = 16,
    this.onDragStart,
    this.onDragEnd,
  });

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  static const double _trackArea = 44;
  static const double _previewW = 184;
  static const double _previewH = 104;
  static const double _labelH = 28;
  static const double _previewGap = 8;
  static const double _cancelSize = 46;
  static const double _cancelOffset = 72;
  static const double _cancelHitRadius = 40;
  static const double _bigFraction = 0.9;
  static const double _bigMaxHeightFraction = 0.6;
  static const double _screenMargin = 10;
  static const double _moveSlop = 8;
  // Fine scrubbing while the picture is enlarged: sideways movement moves the
  // time by only a fraction of what it does on the bar. The higher the finger
  // is above the bar, the finer (slower) it gets.
  static const double _fineMax = 0.25;
  static const double _fineMin = 0.04;
  static const double _fineRange = 250;
  static const Duration _scrubAnim = Duration(milliseconds: 70);
  static const Duration _zoomAnim = Duration(milliseconds: 240);
  static const Duration _commitAnim = Duration(milliseconds: 520);
  static const Duration _fadeAnim = Duration(milliseconds: 200);

  final _trackKey = GlobalKey();
  final _portal = OverlayPortalController();

  double? _dragMs;
  double _lastDx = 0;
  bool _enlarged = false;
  DateTime _zoomUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _overCancel = false;
  bool _down = false;
  bool _started = false;
  Offset _downLocal = Offset.zero;
  int _commitPhase = 0;
  double? _commitMs;
  Timer? _commitTimer;
  double _lastMaxMs = 0;
  double _lastW = 0;
  double? _burstFrac;
  double _burstDy = _trackArea / 2 + _cancelOffset;
  int _burstId = 0;
  double _cancelDy = _trackArea / 2 + _cancelOffset;

  Offset? _trackOrigin;
  double _trackWidth = 0;
  Size? _screen;

  Player? _preview;
  VideoController? _previewCtrl;
  String? _previewFor;
  bool _previewReady = false;
  Timer? _seekTimer;
  int? _pendingSeekMs;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _seekTimer?.cancel();
    _commitTimer?.cancel();
    _preview?.dispose();
    super.dispose();
  }

  bool get _hasVideo => (widget.hub.player.state.width ?? 0) > 0;

  Future<void> _ensurePreview() async {
    if (!_hasVideo) return;
    final media = widget.hub.currentMedia;
    if (media == null) return;
    if (_preview == null) {
      _preview = Player(
        configuration: const PlayerConfiguration(bufferSize: 16 * 1024 * 1024),
      );
      _previewCtrl = VideoController(_preview!);
      await _preview!.setVolume(0);
      if (mounted) setState(() {});
    }
    if (_previewFor != media.uri) {
      _previewFor = media.uri;
      _previewReady = false;
      try {
        await _preview!.open(
          Media(media.uri, httpHeaders: media.httpHeaders),
          play: false,
        );
        await _preview!.setVolume(0);
        _previewReady = true;
      } catch (e) {
        debugPrint('[PalmTunes] Preview open failed -> $e');
        _previewFor = null;
      }
    } else {
      _previewReady = true;
    }
    _flushSeek();
  }

  void _queuePreviewSeek(int ms) {
    _pendingSeekMs = ms;
    if (!_previewReady) return;
    final since = DateTime.now().difference(_lastSeek).inMilliseconds;
    _seekTimer?.cancel();
    if (since >= 90) {
      _flushSeek();
    } else {
      _seekTimer = Timer(Duration(milliseconds: 90 - since), _flushSeek);
    }
  }

  void _flushSeek() {
    final ms = _pendingSeekMs;
    final p = _preview;
    if (ms == null || p == null || !_previewReady) return;
    _pendingSeekMs = null;
    _lastSeek = DateTime.now();
    p.seek(Duration(milliseconds: ms));
  }

  double _msAt(double dx, double w, double maxMs) =>
      w <= 0 ? 0 : (dx / w).clamp(0.0, 1.0) * maxMs;

  Rect _smallRect(double ms) {
    final origin = _trackOrigin!;
    final screen = _screen!;
    final frac = _lastMaxMs > 0 ? (ms / _lastMaxMs).clamp(0.0, 1.0) : 0.0;
    final gx = origin.dx + frac * _trackWidth;
    final left = (gx - _previewW / 2)
        .clamp(
          _screenMargin,
          math.max(_screenMargin, screen.width - _previewW - _screenMargin),
        )
        .toDouble();
    final top = math.max(
      _screenMargin,
      origin.dy - _previewGap - _labelH - _previewH,
    );
    return Rect.fromLTWH(left, top, _previewW, _previewH + _labelH);
  }

  Rect _bigRect() {
    final screen = _screen!;
    var w = screen.width * _bigFraction;
    var h = w * 9 / 16;
    final maxH = screen.height * _bigMaxHeightFraction;
    if (h > maxH) {
      h = maxH;
      w = h * 16 / 9;
    }
    final total = h + _labelH;
    return Rect.fromLTWH(
      (screen.width - w) / 2,
      (screen.height - total) / 2,
      w,
      total,
    );
  }

  void _setEnlarged(bool v) {
    if (_enlarged == v) return;
    _enlarged = v;
    _zoomUntil = DateTime.now().add(_zoomAnim);
  }

  void _resetCommit() {
    _commitTimer?.cancel();
    _commitTimer = null;
    if (_commitPhase != 0) _preview?.pause();
    _commitPhase = 0;
    _commitMs = null;
  }

  void _start(Offset local, double w, double maxMs) {
    if (maxMs <= 0) return;
    _resetCommit();
    _lastMaxMs = maxMs;
    _lastW = w;
    _lastDx = local.dx;
    widget.onDragStart?.call();
    final ms = _msAt(local.dx, w, maxMs);
    setState(() {
      _dragMs = ms;
      _overCancel = false;
      _enlarged = false;
    });
    _portal.show();
    _pendingSeekMs = ms.round();
    _ensurePreview();
  }

  void _update(Offset local, double w, double maxMs) {
    final current = _dragMs;
    if (current == null || maxMs <= 0 || _commitPhase != 0) return;
    _lastMaxMs = maxMs;
    _lastW = w;
    final dx = local.dx - _lastDx;
    _lastDx = local.dx;
    final x = current / maxMs * w;
    final center = Offset(x, _cancelDy);
    if ((local - center).distance <= _cancelHitRadius) {
      setState(() {
        _setEnlarged(false);
        _overCancel = true;
      });
      return;
    }
    final origin = _trackOrigin;
    if (origin != null && _screen != null) {
      final global = origin + local;
      // Entering: the finger has to reach the small picture above the thumb.
      // Staying: the big picture is centred on the screen, so once it is
      // enlarged it stays enlarged while the finger is anywhere above the bar
      // (or inside the big picture) and only shrinks when it comes back down.
      final keep =
          _enlarged && (local.dy < -_previewGap || _bigRect().contains(global));
      if (keep || (!_enlarged && _smallRect(current).contains(global))) {
        var ms = current;
        if (_enlarged) {
          final up = (-local.dy - _previewGap).clamp(0.0, _fineRange);
          final factor = _fineMax - (_fineMax - _fineMin) * (up / _fineRange);
          ms = (current + dx / w * maxMs * factor).clamp(0.0, maxMs);
          _queuePreviewSeek(ms.round());
        }
        setState(() {
          _overCancel = false;
          _setEnlarged(true);
          _dragMs = ms;
        });
        return;
      }
    }
    final ms = _msAt(local.dx, w, maxMs);
    setState(() {
      _overCancel = false;
      _setEnlarged(false);
      _dragMs = ms;
    });
    _queuePreviewSeek(ms.round());
  }

  void _end() {
    final ms = _dragMs;
    if (ms == null) return;
    final cancel = _overCancel;
    final commit = _enlarged && !cancel;
    _seekTimer?.cancel();
    _pendingSeekMs = null;
    if (commit) {
      _commit(ms);
      widget.onDragEnd?.call();
      return;
    }
    _portal.hide();
    setState(() {
      _dragMs = null;
      _overCancel = false;
      _enlarged = false;
      if (cancel && _lastMaxMs > 0) {
        // The bubble bursts where the X is, not on the bar.
        _burstFrac = (ms / _lastMaxMs).clamp(0.0, 1.0);
        _burstDy = _cancelDy;
        _burstId++;
      }
    });
    if (!cancel) {
      widget.hub.player.seek(Duration(milliseconds: ms.round()));
    }
    widget.onDragEnd?.call();
  }

  /// Let go on the enlarged picture: it zooms up to the whole screen,
  /// covering the old video, and then fades away to reveal the main video,
  /// which carries on playing from that spot.
  void _commit(double ms) {
    final hub = widget.hub;
    hub.player.seek(Duration(milliseconds: ms.round()));
    if (!hub.isPlaying) hub.player.play();
    _preview?.play();
    setState(() {
      _commitMs = ms;
      _dragMs = null;
      _overCancel = false;
      _commitPhase = 1;
    });
    _commitTimer?.cancel();
    _commitTimer = Timer(_commitAnim + const Duration(milliseconds: 120), () {
      if (!mounted || _commitPhase != 1) return;
      setState(() => _commitPhase = 2);
      _commitTimer = Timer(_fadeAnim, () {
        if (!mounted || _commitPhase != 2) return;
        _preview?.pause();
        _portal.hide();
        setState(() {
          _commitPhase = 0;
          _commitMs = null;
          _enlarged = false;
        });
      });
    });
  }

  void _clearBurst(int id) {
    if (!mounted || id != _burstId) return;
    setState(() => _burstFrac = null);
  }

  // ---- raw touches: they keep working inside a scrolling list -----------------

  void _onDown(PointerDownEvent e, double w, double maxMs) {
    if (maxMs <= 0) return;
    _down = true;
    _started = false;
    _downLocal = e.localPosition;
    _lastW = w;
    _lastMaxMs = maxMs;
  }

  void _onMove(PointerMoveEvent e, double w, double maxMs) {
    if (!_down) return;
    if (!_started) {
      if ((e.localPosition - _downLocal).distance < _moveSlop) return;
      _started = true;
      _start(_downLocal, w, maxMs);
    }
    _update(e.localPosition, w, maxMs);
  }

  void _onUp(PointerUpEvent e, double w, double maxMs) {
    if (!_down) return;
    _down = false;
    if (!_started) {
      // A plain tap jumps to that spot.
      widget.hub.player.seek(
        Duration(milliseconds: _msAt(e.localPosition.dx, w, maxMs).round()),
      );
      return;
    }
    _started = false;
    _end();
  }

  void _onCancel() {
    if (!_down) return;
    _down = false;
    if (_started) {
      _started = false;
      _end();
    }
  }

  // ---- the floating picture + the X ---------------------------------------------------

  Widget _buildDragOverlay(BuildContext context) {
    final ms = _dragMs ?? _commitMs;
    final box = _trackKey.currentContext?.findRenderObject() as RenderBox?;
    final overlayBox =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (ms == null ||
        box == null ||
        overlayBox == null ||
        !box.hasSize ||
        !overlayBox.hasSize ||
        _lastMaxMs <= 0) {
      return const SizedBox.shrink();
    }
    final accent = Theme.of(context).colorScheme.primary;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
    _trackOrigin = origin;
    _trackWidth = box.size.width;
    _screen = overlayBox.size;
    // Keep the X on screen near the bottom edge.
    final maxCenterDy =
        overlayBox.size.height - origin.dy - _cancelSize / 2 - 14;
    _cancelDy = math.min(_trackArea / 2 + _cancelOffset, maxCenterDy);

    final committing = _commitPhase > 0;
    final Rect rect;
    if (committing) {
      rect = Offset.zero & overlayBox.size;
    } else if (_enlarged) {
      rect = _bigRect();
    } else {
      rect = _smallRect(ms);
    }
    final zooming = DateTime.now().isBefore(_zoomUntil);
    final Duration duration;
    if (committing) {
      duration = _commitAnim;
    } else if (_enlarged || zooming) {
      duration = _zoomAnim;
    } else {
      duration = _scrubAnim;
    }
    final frac = (ms / _lastMaxMs).clamp(0.0, 1.0);
    final gx = origin.dx + frac * _trackWidth;

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: duration,
              curve: committing ? Curves.easeInOutCubic : Curves.easeOutCubic,
              left: rect.left,
              top: rect.top,
              width: rect.width,
              height: rect.height,
              child: AnimatedOpacity(
                duration: _fadeAnim,
                opacity: _commitPhase == 2 ? 0 : 1,
                child: _buildPreview(accent, ms, committing),
              ),
            ),
            if (!committing)
              Positioned(
                left: gx - _cancelSize / 2,
                top: origin.dy + _cancelDy - _cancelSize / 2,
                child: _buildCancel(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(Color accent, double ms, bool committing) {
    final showVideo = _hasVideo && _previewCtrl != null;
    final radius = committing ? 0.0 : (_enlarged ? 18.0 : 10.0);
    final time = formatDuration(Duration(milliseconds: ms.round()));
    final box = Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(radius),
        border: committing
            ? null
            : Border.all(
                color: _overCancel
                    ? Colors.white24
                    : accent.withValues(alpha: _enlarged ? 0.9 : 0.75),
                width: _enlarged ? 2 : 1.5,
              ),
        boxShadow: committing
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: _enlarged ? 48 : 16,
                ),
                if (_enlarged)
                  BoxShadow(
                    color: accent.withValues(alpha: 0.3),
                    blurRadius: 36,
                  ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(math.max(0.0, radius - 1)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!showVideo) ThumbImage(source: widget.item.thumbnailUrl),
            if (showVideo)
              Video(
                controller: _previewCtrl!,
                controls: NoVideoControls,
                fill: Colors.black,
              ),
            if (!committing)
              AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: _overCancel ? 1 : 0,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.6),
                  alignment: Alignment.center,
                  child: const Text(
                    'Release to cancel',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
    if (committing) return box;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: box),
        SizedBox(
          height: _labelH,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(
                color: _enlarged
                    ? accent.withValues(alpha: 0.85)
                    : Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Text(
                _enlarged ? 'Release to jump to $time' : time,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCancel() {
    final danger = Colors.redAccent.shade200;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 140),
      opacity: _enlarged ? 0.3 : 1,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: _overCancel ? 1.18 : 1,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: _cancelSize,
          height: _cancelSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _overCancel ? danger : Colors.black.withValues(alpha: 0.6),
            border: Border.all(
              color: _overCancel ? Colors.redAccent.shade100 : Colors.white38,
              width: 1.5,
            ),
            boxShadow: _overCancel
                ? [
                    BoxShadow(
                      color: danger.withValues(alpha: 0.6),
                      blurRadius: 16,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.close_rounded,
            size: 22,
            color: _overCancel ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final hub = widget.hub;
    const timeStyle = TextStyle(color: Colors.white70, fontSize: 12.5);

    return StreamBuilder<Duration>(
      stream: hub.player.stream.position,
      initialData: hub.player.state.position,
      builder: (context, snap) {
        final dur = hub.player.state.duration;
        final total = dur > Duration.zero
            ? dur
            : (widget.item.duration ?? Duration.zero);
        final maxMs = total.inMilliseconds.toDouble();
        final posMs = (snap.data ?? Duration.zero).inMilliseconds.toDouble();
        final value = maxMs > 0
            ? (_dragMs ?? posMs).clamp(0.0, maxMs).toDouble()
            : 0.0;

        return OverlayPortal(
          controller: _portal,
          overlayChildBuilder: _buildDragOverlay,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.horizontalPadding),
            child: Column(
              children: [
                LayoutBuilder(
                  builder: (context, c) {
                    final w = c.maxWidth;
                    final frac = maxMs > 0 ? value / maxMs : 0.0;
                    final x = frac * w;
                    final dragging = _dragMs != null;
                    final barH = dragging ? 8.0 : 6.0;
                    final thumbR = dragging ? 11.0 : 8.0;
                    final activeColor = _overCancel ? Colors.white38 : accent;
                    final burstId = _burstId;

                    // The eager recogniser keeps a list behind the bar from
                    // starting to scroll while a finger is on it; the Listener
                    // still gets every touch.
                    return RawGestureDetector(
                      gestures: {
                        EagerGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                              EagerGestureRecognizer
                            >(() => EagerGestureRecognizer(), (_) {}),
                      },
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: (e) => _onDown(e, w, maxMs),
                        onPointerMove: (e) => _onMove(e, w, maxMs),
                        onPointerUp: (e) => _onUp(e, w, maxMs),
                        onPointerCancel: (_) => _onCancel(),
                        child: SizedBox(
                          key: _trackKey,
                          height: _trackArea,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                left: 0,
                                right: 0,
                                top: (_trackArea - barH) / 2,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  height: barH,
                                  decoration: BoxDecoration(
                                    color: Colors.white24,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 0,
                                top: (_trackArea - barH) / 2,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  width: x,
                                  height: barH,
                                  decoration: BoxDecoration(
                                    color: activeColor,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: x - thumbR,
                                top: _trackArea / 2 - thumbR,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 120),
                                  width: thumbR * 2,
                                  height: thumbR * 2,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: activeColor,
                                    boxShadow: [
                                      BoxShadow(
                                        color: activeColor.withValues(
                                          alpha: 0.5,
                                        ),
                                        blurRadius: dragging ? 12 : 6,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (_burstFrac != null)
                                Positioned(
                                  left:
                                      _burstFrac! * w - _BubbleBurst.extent / 2,
                                  top: _burstDy - _BubbleBurst.extent / 2,
                                  child: IgnorePointer(
                                    child: _BubbleBurst(
                                      key: ValueKey(burstId),
                                      color: accent,
                                      onDone: () => _clearBurst(burstId),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        formatDuration(Duration(milliseconds: value.round())),
                        style: timeStyle,
                      ),
                      Text(
                        formatDuration(total > Duration.zero ? total : null),
                        style: timeStyle,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The bubble that bursts at the thumb when a scrub is cancelled.
class _BubbleBurst extends StatefulWidget {
  static const double extent = 84;

  final Color color;
  final VoidCallback onDone;

  const _BubbleBurst({super.key, required this.color, required this.onDone});

  @override
  State<_BubbleBurst> createState() => _BubbleBurstState();
}

class _BubbleBurstState extends State<_BubbleBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(() => widget.onDone());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(
        size: const Size.square(_BubbleBurst.extent),
        painter: _BurstPainter(t: _c.value, color: widget.color),
      ),
    );
  }
}

class _BurstPainter extends CustomPainter {
  static const int _drops = 10;
  static const double _popEnd = 0.18;

  final double t;
  final Color color;

  _BurstPainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final fade = (1 - t).clamp(0.0, 1.0);

    if (t < _popEnd) {
      final k = t / _popEnd;
      final r = 8 + 6 * Curves.easeOut.transform(k);
      canvas.drawCircle(
        c,
        r,
        Paint()..color = color.withValues(alpha: 1 - k * 0.4),
      );
      canvas.drawCircle(
        c.translate(-r * 0.3, -r * 0.3),
        r * 0.28,
        Paint()..color = Colors.white.withValues(alpha: 0.7 * (1 - k)),
      );
    }

    final rt = Curves.easeOutCubic.transform(t);
    final ringR = 10 + 24 * rt;
    canvas.drawCircle(
      c,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6 + 2.6 * fade
        ..color = Color.lerp(
          color,
          Colors.white,
          0.35,
        )!.withValues(alpha: 0.85 * fade),
    );

    if (t > 0.08) {
      final dt = ((t - 0.08) / 0.92).clamp(0.0, 1.0);
      final dist = 12 + 26 * Curves.easeOutQuart.transform(dt);
      final dropR = 3.0 * (1 - dt) + 0.4;
      for (var i = 0; i < _drops; i++) {
        final angle = i * 2 * math.pi / _drops + 0.25 + (i.isEven ? 0.0 : 0.12);
        final reach = dist * (i.isEven ? 1.0 : 0.82);
        final p = c + Offset(math.cos(angle), math.sin(angle)) * reach;
        canvas.drawCircle(
          p,
          dropR * (i.isEven ? 1.0 : 0.75),
          Paint()
            ..color = Color.lerp(
              color,
              Colors.white,
              0.25 + 0.5 * dt,
            )!.withValues(alpha: (1 - dt).clamp(0.0, 1.0)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) =>
      old.t != t || old.color != color;
}
