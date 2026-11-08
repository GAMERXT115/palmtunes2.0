import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'downloads.dart';
import 'player_hub.dart';
import 'ui.dart';

class YtVideo {
  final String id;
  final String title;
  final String author;
  final Duration? duration;
  final String thumbnailUrl;

  const YtVideo({
    required this.id,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnailUrl,
  });

  String get url => 'https://www.youtube.com/watch?v=$id';

  factory YtVideo.fromVideo(yt.Video v) => YtVideo(
    id: v.id.value,
    title: v.title,
    author: v.author,
    duration: v.duration,
    thumbnailUrl: v.thumbnails.highResUrl,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'author': author,
    'durationMs': duration?.inMilliseconds,
    'thumbnailUrl': thumbnailUrl,
  };

  factory YtVideo.fromJson(Map<String, dynamic> j) => YtVideo(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    author: j['author'] as String? ?? '',
    duration: j['durationMs'] == null
        ? null
        : Duration(milliseconds: j['durationMs'] as int),
    thumbnailUrl: j['thumbnailUrl'] as String? ?? '',
  );
}

String formatDuration(Duration? d) {
  if (d == null) return '--:--';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _yt = yt.YoutubeExplode();
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  Timer? _debounce;
  List<String> _suggestions = [];
  bool _showSuggestions = false;
  int _suggestToken = 0;

  List<YtVideo> _results = [];
  yt.VideoSearchList? _page;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  int _searchToken = 0;

  late final NavController _nav;

  @override
  void initState() {
    super.initState();
    _nav = context.read<NavController>();
    _nav.addListener(_onNav);
    _scroll.addListener(_onScroll);
    _focus.addListener(() {
      if (!_focus.hasFocus && mounted) setState(() => _showSuggestions = false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _onNav();
    });
  }

  @override
  void dispose() {
    _nav.removeListener(_onNav);
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    _scroll.dispose();
    _yt.close();
    super.dispose();
  }

  void _onNav() {
    final q = _nav.takePendingQuery();
    if (q == null || !mounted) return;
    _ctrl.value = TextEditingValue(
      text: q,
      selection: TextSelection.collapsed(offset: q.length),
    );
    _search(q);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => _fetchSuggestions(text),
    );
  }

  Future<void> _fetchSuggestions(String query) async {
    final token = ++_suggestToken;
    try {
      final res = await _yt.search.getQuerySuggestions(query.trim());
      if (!mounted || token != _suggestToken) return;
      setState(() {
        _suggestions = res.take(6).toList();
        _showSuggestions = _focus.hasFocus && _suggestions.isNotEmpty;
      });
    } catch (_) {}
  }

  void _runSuggestion(String s) {
    _ctrl.value = TextEditingValue(
      text: s,
      selection: TextSelection.collapsed(offset: s.length),
    );
    _search(s);
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    _debounce?.cancel();
    _focus.unfocus();
    final token = ++_searchToken;
    setState(() {
      _showSuggestions = false;
      _loading = true;
      _loadingMore = false;
      _error = null;
      _results = [];
      _page = null;
      _hasMore = false;
    });
    try {
      final page = await _yt.search.search(q);
      if (!mounted || token != _searchToken) return;
      setState(() {
        _page = page;
        _hasMore = true;
        _results = page
            .where((v) => !v.isLive && v.duration != null)
            .map(YtVideo.fromVideo)
            .toList();
        _loading = false;
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (_) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _loading = false;
        _error = 'Could not load results. Check your connection and try again.';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_page == null || !_hasMore || _loading || _loadingMore) return;
    final token = _searchToken;
    setState(() => _loadingMore = true);
    try {
      final next = await _page!.nextPage();
      if (!mounted || token != _searchToken) return;
      setState(() {
        _loadingMore = false;
        if (next == null || next.isEmpty) {
          _hasMore = false;
          return;
        }
        _page = next;
        final ids = _results.map((e) => e.id).toSet();
        _results.addAll(
          next
              .where((v) => !v.isLive && v.duration != null)
              .map(YtVideo.fromVideo)
              .where((v) => ids.add(v.id)),
        );
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _play(int index) {
    context.read<PlayerHub>().playOnline(_results, index);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Search',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 10),
          _searchBar(),
          if (_showSuggestions && _suggestions.isNotEmpty) _suggestionList(),
          const SizedBox(height: 10),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _searchBar() {
    final accent = Theme.of(context).colorScheme.primary;
    return GlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          const SizedBox(width: 8),
          Icon(Icons.search_rounded, color: accent, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: _search,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'Search songs or videos',
                hintStyle: TextStyle(color: Colors.white38),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          if (_ctrl.text.isNotEmpty)
            IconButton(
              onPressed: () {
                _ctrl.clear();
                _onChanged('');
                setState(() {});
              },
              icon: const Icon(Icons.close_rounded, size: 20),
              color: Colors.white54,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Widget _suggestionList() {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: GlassContainer(
        borderRadius: 14,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            for (final s in _suggestions)
              InkWell(
                onTap: () => _runSuggestion(s),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.search_rounded,
                        size: 17,
                        color: Colors.white38,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          s,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          _ctrl.value = TextEditingValue(
                            text: s,
                            selection: TextSelection.collapsed(
                              offset: s.length,
                            ),
                          );
                          _fetchSuggestions(s);
                        },
                        child: const Padding(
                          padding: EdgeInsets.only(left: 8),
                          child: Icon(
                            Icons.north_west_rounded,
                            size: 16,
                            color: Colors.white38,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const _SkeletonList();
    if (_error != null) {
      return _MessageState(
        icon: Icons.wifi_off_rounded,
        title: 'Something went wrong',
        message: _error!,
      );
    }
    if (_results.isEmpty) {
      return const _MessageState(
        icon: Icons.music_note_rounded,
        title: 'Find something to play',
        message: 'Search for a song, then tap it to play or download it.',
      );
    }
    return ListView.builder(
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 160),
      itemCount: _results.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _results.length) {
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
          );
        }
        return VideoTile(video: _results[i], onTap: () => _play(i));
      },
    );
  }
}

/// One search result: thumbnail, title, channel, length and a download button.
class VideoTile extends StatelessWidget {
  final YtVideo video;
  final VoidCallback onTap;

  const VideoTile({super.key, required this.video, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final current = context.select<PlayerHub, String?>(
      (h) => h.current?.videoId,
    );
    final accent = Theme.of(context).colorScheme.primary;
    final playing = current == video.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: Colors.white.withValues(alpha: 0.05),
              border: Border.all(
                color: playing
                    ? accent.withValues(alpha: 0.6)
                    : Colors.white.withValues(alpha: 0.07),
              ),
            ),
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: SizedBox(
                        width: 128,
                        height: 72,
                        child: Image.network(
                          video.thumbnailUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: Colors.white10,
                            child: const Icon(
                              Icons.music_note_rounded,
                              color: Colors.white24,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 5,
                      bottom: 5,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          formatDuration(video.duration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: playing ? accent : Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          height: 1.25,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        video.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                DownloadButton(video: video),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Download / progress ring / done tick for one video.
class DownloadButton extends StatelessWidget {
  final YtVideo video;
  final double size;

  const DownloadButton({super.key, required this.video, this.size = 40});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final store = context.watch<DownloadsStore>();
    final state = store.stateOf(video.id);
    final progress = store.progressOf(video.id);

    Widget icon;
    VoidCallback? onTap;
    switch (state) {
      case DownloadState.done:
        icon = const Icon(
          Icons.check_circle_rounded,
          color: AppColors.success,
          size: 24,
        );
      case DownloadState.queued:
        icon = const Icon(
          Icons.schedule_rounded,
          color: Colors.white54,
          size: 22,
        );
        onTap = () => store.cancelDownload(video.id);
      case DownloadState.downloading:
        icon = SizedBox(
          width: 24,
          height: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: progress,
                strokeWidth: 2.6,
                color: accent,
                backgroundColor: Colors.white12,
              ),
              const Icon(Icons.close_rounded, size: 12, color: Colors.white70),
            ],
          ),
        );
        onTap = () => store.cancelDownload(video.id);
      case DownloadState.failed:
        icon = Icon(
          Icons.refresh_rounded,
          color: Colors.redAccent.shade200,
          size: 24,
        );
        onTap = () => store.retryDownload(video.id);
      case DownloadState.none:
        icon = const Icon(
          Icons.download_rounded,
          color: Colors.white70,
          size: 24,
        );
        onTap = () async {
          final msg = await store.startDownload(video);
          if (msg != null) Notch.show(msg, icon: Icons.info_outline_rounded);
        };
    }
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(onPressed: onTap, icon: icon, padding: EdgeInsets.zero),
    );
  }
}

class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final a = 0.05 + 0.05 * _c.value;
        Widget box(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: a),
            borderRadius: BorderRadius.circular(8),
          ),
        );
        return ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 7,
          itemBuilder: (_, _) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                box(128, 72),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      box(double.infinity, 14),
                      const SizedBox(height: 8),
                      box(120, 12),
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

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 120, left: 24, right: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: accent.withValues(alpha: 0.12),
              ),
              child: Icon(icon, color: accent, size: 32),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
