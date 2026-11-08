import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'bass_meter.dart';
import 'player_hub.dart';
import 'ui.dart';

/// The small player that sits above the navigation bar while a song is
/// loaded and the full player is closed. Tap it (or swipe up) to open the
/// full player.
class MiniBar extends StatelessWidget {
  const MiniBar({super.key});

  @override
  Widget build(BuildContext context) {
    final hub = context.watch<PlayerHub>();
    final item = hub.current;
    if (item == null) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    final meter = context.read<BassMeter>();

    return GestureDetector(
      onTap: hub.openFullView,
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) < -250) hub.openFullView();
      },
      child: GlassContainer(
        borderRadius: 20,
        opacity: 0.12,
        borderColor: accent.withValues(alpha: 0.3),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: SizedBox(
                      width: 50,
                      height: 50,
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
                    bars: 6,
                    height: 26,
                    barWidth: 3.5,
                    gap: 2.5,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: hub.togglePlay,
                    icon: hub.isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : Icon(
                            hub.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 30,
                          ),
                    color: Colors.white,
                  ),
                  IconButton(
                    onPressed: hub.hasNext ? hub.next : null,
                    icon: const Icon(Icons.skip_next_rounded, size: 28),
                    color: Colors.white,
                    disabledColor: Colors.white24,
                  ),
                  IconButton(
                    onPressed: hub.close,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: Colors.white54,
                    visualDensity: VisualDensity.compact,
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
    );
  }
}
