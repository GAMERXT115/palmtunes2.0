import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bass_meter.dart';
import 'player_hub.dart';
import 'ui.dart';

/// The small player that sits above the navigation bar while a song is
/// loaded and the full player is closed.
///
/// Tap it or swipe it UP to open the full player. Swipe it DOWN to close it
/// and stop the music.
class MiniBar extends StatelessWidget {
  const MiniBar({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<PlayerHub>();
    final item = hub.current;
    if (item == null) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    final meter = context.read<BassMeter>();

    return Dismissible(
      key: ValueKey('mini-${item.videoId}'),
      direction: DismissDirection.vertical,
      dismissThresholds: const {
        DismissDirection.up: 0.2,
        DismissDirection.down: 0.35,
      },
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.up) {
          hub.openFullView();
          return false;
        }
        return true;
      },
      onDismissed: (_) => hub.close(),
      child: GestureDetector(
        onTap: hub.openFullView,
        child: GlassContainer(
          borderRadius: 20,
          opacity: 0.12,
          borderColor: accent.withValues(alpha: 0.3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 2, 6),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: SizedBox(
                        width: 48,
                        height: 48,
                        child: ThumbImage(source: item.thumbnailUrl),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13.5,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            hub.error ?? item.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: hub.error != null
                                  ? Colors.redAccent.shade200
                                  : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    BassBars(
                      level: meter.level,
                      color: accent,
                      bars: 5,
                      height: 24,
                      barWidth: 3,
                      gap: 2,
                    ),
                    const SizedBox(width: 2),
                    _MiniButton(
                      icon: Icons.skip_previous_rounded,
                      onTap: hub.previous,
                    ),
                    hub.isLoading
                        ? const SizedBox(
                            width: 44,
                            height: 44,
                            child: Padding(
                              padding: EdgeInsets.all(11),
                              child: CircularProgressIndicator(strokeWidth: 2.4),
                            ),
                          )
                        : _MiniButton(
                            icon: hub.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 32,
                            onTap: hub.togglePlay,
                          ),
                    _MiniButton(
                      icon: Icons.skip_next_rounded,
                      onTap: hub.hasNext ? hub.next : null,
                    ),
                  ],
                ),
              ),
              StreamBuilder<Duration>(
                stream: hub.player.stream.position,
                initialData: hub.player.state.position,
                builder: (context, snap) {
                  final dur = hub.player.state.duration.inMilliseconds;
                  final pos = (snap.data ?? Duration.zero).inMilliseconds;
                  return ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(20),
                    ),
                    child: LinearProgressIndicator(
                      value: dur <= 0 ? 0 : (pos / dur).clamp(0.0, 1.0),
                      minHeight: 3,
                      color: accent,
                      backgroundColor: Colors.white10,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;

  const _MiniButton({required this.icon, required this.onTap, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, size: size),
      color: Colors.white,
      disabledColor: Colors.white24,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
    );
  }
}
