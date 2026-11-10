import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_volume_controller/flutter_volume_controller.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'bass_meter.dart';
import 'downloads.dart';
import 'main.dart';
import 'player_screen.dart';
import 'search.dart';
import 'settings.dart';
import 'ui.dart';
import 'yt_streams.dart';

class NavController extends ChangeNotifier {
  static const int listTab = 0;
  static const int searchTab = 1;
  static const int downloadsTab = 2;
  static const int settingsTab = 3;

  int _index = listTab;
  String? _pendingQuery;

  int get index => _index;

  void setIndex(int i) {
    if (i == _index) return;
    _index = i;
    notifyListeners();
  }

  void searchFor(String query) {
    _pendingQuery = query;
    _index = searchTab;
    notifyListeners();
  }

  String? takePendingQuery() {
    final q = _pendingQuery;
    _pendingQuery = null;
    return q;
  }
}

class PlayItem {
  final String videoId;
  final String title;
  final String author;
  final Duration? duration;
  final String thumbnailUrl;
  final String? localPath;
  final String? localAudioPath;

  const PlayItem({
    required this.videoId,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnailUrl,
    this.localPath,
    this.localAudioPath,
  });

  factory PlayItem.fromYt(YtVideo v) => PlayItem(
    videoId: v.id,
    title: v.title,
    author: v.author,
    duration: v.duration,
    thumbnailUrl: v.thumbnailUrl,
  );

  factory PlayItem.fromDownload(DownloadedVideo v) => PlayItem(
    videoId: v.videoId,
    title: v.title,
    author: v.author,
    duration: v.duration,
    thumbnailUrl: v.thumbSource,
    localPath: v.filePath,
    localAudioPath: v.audioPath,
  );
}

class _Resolved {
  final String uri;
  final String? audioUri;
  final bool remote;
  final int? height;
  final Map<String, String>? headers;
  const _Resolved(
    this.uri,
    this.audioUri,
    this.remote,
    this.height,
    this.headers,
  );
}

class PlayerHub extends ChangeNotifier {
  static const int _maxRetries = 2;
  static const Duration _retryDelay = Duration(milliseconds: 400);
  static const Duration _relatedTimeout = Duration(seconds: 30);
  static const Duration _earlyEndSlack = Duration(seconds: 5);
  static const Duration _resumeWait = Duration(seconds: 10);
  static const Duration _restartThreshold = Duration(seconds: 3);

  final SettingsStore settings;
  final DownloadsStore downloads;
  late Player _active;
  late VideoController _activeCtrl;
  Player? _spare;
  VideoController? _spareCtrl;
  _XfPlan? _plan;
  _Crossfade? _xf;
  Future<void>? _preloadTail;
  String? _audioSrc;
  Map<String, String>? _audioHeaders;
  final _random = Random();
  final List<StreamSubscription> _subs = [];

  List<PlayItem> _queue = [];
  int _index = -1;
  int _token = 0;
  int _skipToken = 0;
  bool _loading = false;
  bool _shuffle = false;
  bool _isPlayerOpen = false;
  bool _currentIsRemote = false;
  bool _currentHasSeparateAudio = false;
  int? _currentHeight;
  String? _error;

  bool _autoRecommend = false;
  bool _fullscreen = false;
  bool _muted = false;
  double _volume = 100;
  Media? _media;
  final Set<String> _played = {};
  final List<int> _history = [];
  final Set<int> _shuffleSeen = {};
  Future<List<YtVideo>>? _relatedFuture;
  String? _relatedFor;
  List<YtVideo> _related = [];
  bool _relatedLoading = false;
  int _retries = 0;
  int _retryToken = -1;
  bool _retrying = false;

  PlayerHub({required this.settings, required this.downloads}) {
    _active = _createPlayer();
    _activeCtrl = VideoController(_active);
  }

  /// The player that owns the current song. It changes when a crossfade
  /// hands over to the next song, so always read it through this getter.
  Player get player => _active;
  VideoController get controller => _activeCtrl;

  List<PlayItem> get queue => List.unmodifiable(_queue);
  int get index => _index;
  PlayItem? get current =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;
  bool get isLoading => _loading;
  bool get isPlaying => player.state.playing;
  bool get shuffle => _shuffle;
  bool get isPlayerOpen => _isPlayerOpen;
  bool get isFullscreen => _fullscreen;
  bool get isMuted => _muted;
  double get volume => _volume;
  bool get autoRecommend => _autoRecommend;
  Media? get currentMedia => _media;
  int? get currentHeight => _currentHeight;
  String? get error => _error;
  bool get recommendationsLoading => _relatedLoading;
  List<YtVideo> get recommendations {
    final id = current?.videoId;
    return _related.where((v) => v.id != id).toList();
  }

  bool get hasNext {
    if (_autoRecommend && current != null) return true;
    return _shuffle ? _queue.length > 1 : _index < _queue.length - 1;
  }

  bool get hasPrevious => _index > 0 || (_shuffle && _history.isNotEmpty);

  void _configureNetwork(Player pl) {
    final native = pl.platform;
    if (native is! NativePlayer) return;
    unawaited(
      native.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
      ),
    );
    unawaited(native.setProperty('network-timeout', '20'));
    unawaited(native.setProperty('demuxer-max-bytes', '64MiB'));
    unawaited(native.setProperty('demuxer-readahead-secs', '30'));
  }

  void _onCompleted(bool done) {
    if (!done || _loading || _retrying) return;
    final dur = player.state.duration;
    final pos = player.state.position;
    if (_currentIsRemote &&
        dur > Duration.zero &&
        pos < dur - _earlyEndSlack &&
        _retries < _maxRetries) {
      _retryCurrent(
        pos,
        'stream ended early at ${pos.inSeconds}s of ${dur.inSeconds}s',
      );
      return;
    }
    if (settings.autoplayNext && hasNext) next();
  }

  void _onError(String e) {
    if (e.isEmpty) return;
    debugPrint('[PalmTunes] Player error -> ${e.split('?').first}');
    final item = current;
    if (item == null) return;
    if (_currentIsRemote && _currentHasSeparateAudio) {
      YtStreams.instance.markNoHd(item.videoId);
    }
    if (_currentIsRemote && _retries < _maxRetries) {
      _retryCurrent(player.state.position, e);
      return;
    }
    if (_retrying) return;
    final why = e.split('?').first.trim();
    _error = why.isEmpty
        ? 'Playback error'
        : 'Playback error: ${why.length > 90 ? why.substring(0, 90) : why}';
    notifyListeners();
  }

  void _retryCurrent(Duration position, String reason) {
    final token = _token;
    if (_retryToken == token) return;
    _retryToken = token;
    _retries++;
    _retrying = true;
    final item = current;
    if (item != null) YtStreams.instance.invalidate(item.videoId);
    debugPrint(
      '[PalmTunes] Retrying ${item?.videoId} ($_retries/$_maxRetries) at ${position.inSeconds}s -> ${reason.split('?').first}',
    );
    final resume = position > const Duration(seconds: 2) ? position : null;
    Future.delayed(_retryDelay, () async {
      if (token != _token) {
        _retrying = false;
        return;
      }
      try {
        await _playIndex(_index, startAt: resume, retry: true);
      } finally {
        _retrying = false;
      }
    });
  }

  Future<void> playOnline(
    List<YtVideo> list,
    int index, {
    bool openFull = true,
  }) => _start(list.map(PlayItem.fromYt).toList(), index, openFull, true);

  Future<void> playDownloaded(
    List<DownloadedVideo> list,
    int index, {
    bool openFull = true,
  }) =>
      _start(list.map(PlayItem.fromDownload).toList(), index, openFull, false);

  Future<void> _start(
    List<PlayItem> items,
    int index,
    bool openFull,
    bool recommend,
  ) async {
    if (index < 0 || index >= items.length) return;
    _skipToken++;
    _queue = items;
    _index = index;
    _autoRecommend = recommend;
    _played.clear();
    _history.clear();
    _shuffleSeen.clear();
    _relatedFuture = null;
    _relatedFor = null;
    _related = [];
    _relatedLoading = false;
    notifyListeners();
    if (openFull) _openFullView();
    await _playIndex(index);
  }

  void openFullView() => _openFullView();

  void _openFullView() {
    if (_isPlayerOpen) return;
    final ctx = PalmTunesApp.navigatorKey.currentContext;
    if (ctx == null) return;
    VideoPlayerScreen.open(ctx);
  }

  Future<void> _playIndex(
    int i, {
    Duration? startAt,
    bool retry = false,
  }) async {
    if (i < 0 || i >= _queue.length) return;
    _cancelCrossfade();
    _index = i;
    _loading = true;
    _error = null;
    _audioSrc = null;
    _audioHeaders = null;
    if (!retry) _retries = 0;
    final token = ++_token;
    notifyListeners();
    final item = _queue[i];
    if (!retry && player.state.playing) unawaited(player.pause());
    if (_autoRecommend) _prefetchRelated(item);
    try {
      final r = await _resolve(item);
      if (token != _token) return;
      _currentIsRemote = r.remote;
      _currentHasSeparateAudio = r.audioUri != null;
      _currentHeight = r.height;
      _audioSrc = r.audioUri ?? r.uri;
      _audioHeaders = r.headers;
      final media = Media(r.uri, httpHeaders: r.headers);
      final ready = startAt == null
          ? null
          : player.stream.duration
                .firstWhere((d) => d > Duration.zero)
                .timeout(_resumeWait, onTimeout: () => Duration.zero);
      await player.open(media, play: false);
      if (token != _token) return;
      final audio = r.audioUri;
      if (audio != null) {
        await player.setAudioTrack(AudioTrack.uri(audio));
        if (token != _token) return;
      }
      if (ready != null) {
        await ready;
        if (token != _token) return;
        await player.seek(startAt!);
        if (token != _token) return;
      }
      await player.play();
      _media = media;
      _played.add(item.videoId);
      if (!retry && !_isPlayerOpen) {
        Notch.show(
          'Now Playing: ${item.title}',
          icon: Icons.music_note_rounded,
        );
      }
      debugPrint(
        '[PalmTunes] Opened ${r.remote ? 'stream' : 'file'} for ${item.videoId}${r.height != null ? ' at ${r.height}p' : ''}${audio != null ? ' with separate audio' : ''}',
      );
    } on YtFriendlyError catch (e) {
      if (token == _token) _error = e.message;
    } catch (e) {
      debugPrint('[PalmTunes] Could not play ${item.videoId} -> $e');
      if (token == _token) _error = 'Could not play "${item.title}"';
    } finally {
      if (token == _token) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------------
  // Crossfade
  //
  // Two players are used: the one that owns the current song ("active") and a
  // spare one. Shortly before a song ends the next song is opened silently on
  // the spare, then the roles swap and the two are faded against each other
  // (equal-power curve for the sound, eased opacity for the picture).
  // ---------------------------------------------------------------------

  static const Duration _xfPreloadLead = Duration(seconds: 12);
  static const Duration _xfTick = Duration(milliseconds: 40);
  static const Duration _xfMinFade = Duration(milliseconds: 1500);

  bool get isCrossfading => _xf != null;

  /// Eased 0..1 opacity of the incoming video while a crossfade runs.
  final ValueNotifier<double> crossfadeProgress = ValueNotifier<double>(1);

  /// Picture of the song that is fading out (null when no crossfade runs).
  VideoController? get outgoingController => _xf == null ? null : _spareCtrl;
  Player? get outgoingPlayer => _xf == null ? null : _spare;
  PlayItem? get outgoingItem => _xf?.outgoingItem;

  Player _createPlayer() {
    final pl = Player(
      configuration: const PlayerConfiguration(bufferSize: 32 * 1024 * 1024),
    );
    _configureNetwork(pl);
    BassMeter.attachFilter(pl);
    _subs.add(
      pl.stream.playing.listen((_) {
        if (identical(pl, _active)) notifyListeners();
      }),
    );
    _subs.add(
      pl.stream.completed.listen((done) {
        if (identical(pl, _active)) _onCompleted(done);
      }),
    );
    _subs.add(
      pl.stream.error.listen((e) {
        if (identical(pl, _active)) _onError(e);
      }),
    );
    _subs.add(
      pl.stream.position.listen((pos) {
        if (identical(pl, _active)) _onPosition(pos);
      }),
    );
    return pl;
  }

  Player _ensureSpare() {
    var s = _spare;
    if (s == null) {
      s = _createPlayer();
      _spare = s;
      _spareCtrl = VideoController(s);
    }
    return s;
  }

  Duration? _fadeFor(Duration dur) {
    final want = Duration(seconds: settings.crossfadeSeconds);
    final cap = Duration(milliseconds: dur.inMilliseconds ~/ 2 - 1000);
    final fade = want < cap ? want : cap;
    return fade < const Duration(seconds: 2) ? null : fade;
  }

  void _onPosition(Duration pos) {
    final plan = _plan;
    if (!settings.crossfadeEnabled || !settings.autoplayNext) {
      if (plan != null) _dropPlan();
      return;
    }
    if (_xf != null || _loading || _retrying || current == null) return;
    if (plan != null && plan.token != _token) {
      _dropPlan();
      return;
    }
    final dur = _active.state.duration;
    if (dur <= Duration.zero) return;
    final fade = _fadeFor(dur);
    if (fade == null) return;
    final remaining = dur - pos;
    if (remaining > fade + _xfPreloadLead) return;

    var cur = plan;
    if (cur == null) {
      cur = _makePlan();
      if (cur == null) return;
      _plan = cur;
      unawaited(_preload(cur));
      return;
    }
    if (cur.failed || !cur.ready || remaining > fade) return;
    if (!_active.state.playing) return;
    final length = remaining < fade ? remaining : fade;
    if (length < _xfMinFade) {
      // Too little left to blend: let the song end normally.
      cur.failed = true;
      return;
    }
    unawaited(_beginCrossfade(cur, length));
  }

  /// Decides which song follows (same rules as [next]) without changing
  /// anything yet; the bookkeeping runs in `commit` when the fade starts.
  _XfPlan? _makePlan() {
    final item = current;
    if (item == null) return null;
    final token = _token;
    if (_autoRecommend && !_shuffle) {
      final pick = _pickRecommendation(item.videoId);
      if (pick == null) return null;
      final next = PlayItem.fromYt(pick);
      return _XfPlan(next, token, () {
        _played.add(pick.id);
        _queue = [..._queue.take(_index + 1), next];
        _index = _index + 1;
      });
    }
    if (_shuffle && _queue.length > 1) {
      final n = _pickShuffle();
      return _XfPlan(_queue[n], token, () {
        _history.add(_index);
        _index = n;
      });
    }
    if (_index < _queue.length - 1) {
      final n = _index + 1;
      return _XfPlan(_queue[n], token, () {
        _index = n;
      });
    }
    return null;
  }

  Future<void> _preload(_XfPlan plan) {
    final prev = _preloadTail;
    final run = () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      if (plan.cancelled) return;
      try {
        final r = await _resolve(plan.item);
        if (plan.cancelled) return;
        final spare = _ensureSpare();
        final media = Media(r.uri, httpHeaders: r.headers);
        await spare.setVolume(0);
        await spare.open(media, play: false);
        if (plan.cancelled) return;
        final audio = r.audioUri;
        if (audio != null) {
          await spare.setAudioTrack(AudioTrack.uri(audio));
          if (plan.cancelled) return;
        }
        if (spare.state.duration <= Duration.zero) {
          await spare.stream.duration
              .firstWhere((d) => d > Duration.zero)
              .timeout(_resumeWait);
          if (plan.cancelled) return;
        }
        plan.resolved = r;
        plan.media = media;
        plan.ready = true;
      } catch (e) {
        debugPrint('[PalmTunes] Crossfade preload failed -> $e');
        if (!plan.cancelled) plan.failed = true;
      }
    }();
    _preloadTail = run;
    return run;
  }

  void _dropPlan() {
    final plan = _plan;
    if (plan == null) return;
    plan.cancelled = true;
    _plan = null;
    if (_xf == null) {
      final s = _spare;
      if (s != null) unawaited(s.stop());
    }
  }

  Future<void> _beginCrossfade(_XfPlan plan, Duration length) async {
    if (_xf != null) return;
    final incoming = _spare;
    final incomingCtrl = _spareCtrl;
    final r = plan.resolved;
    if (incoming == null || incomingCtrl == null || r == null) return;
    final outgoingItem = current;
    final outgoing = _active;
    final outgoingCtrl = _activeCtrl;

    _plan = null;
    final xf = _Crossfade(length, outgoingItem);
    _xf = xf;

    // The new song is "current" for the whole fade, so the seek bar, title and
    // controls already belong to it.
    _active = incoming;
    _activeCtrl = incomingCtrl;
    _spare = outgoing;
    _spareCtrl = outgoingCtrl;
    plan.commit();
    _currentIsRemote = r.remote;
    _currentHasSeparateAudio = r.audioUri != null;
    _currentHeight = r.height;
    _audioSrc = r.audioUri ?? r.uri;
    _audioHeaders = r.headers;
    _media = plan.media;
    _token++;
    _skipToken++;
    _retries = 0;
    _error = null;
    _loading = false;
    _played.add(plan.item.videoId);
    if (_autoRecommend) _prefetchRelated(plan.item);
    crossfadeProgress.value = 0;
    if ((outgoing.state.rate - incoming.state.rate).abs() > 0.001) {
      unawaited(incoming.setRate(outgoing.state.rate));
    }
    if (!_isPlayerOpen) {
      Notch.show(
        'Now Playing: ${plan.item.title}',
        icon: Icons.music_note_rounded,
      );
    }
    notifyListeners();
    debugPrint(
      '[PalmTunes] Crossfading ${length.inSeconds}s into ${plan.item.videoId}',
    );

    try {
      await incoming.setVolume(0);
      await incoming.play();
    } catch (e) {
      debugPrint('[PalmTunes] Crossfade could not start playback -> $e');
    }
    if (!identical(_xf, xf)) return;
    xf.clock.start();
    xf.timer = Timer.periodic(_xfTick, (_) => _xfStep(xf));
  }

  void _xfStep(_Crossfade xf) {
    if (!identical(_xf, xf)) {
      xf.timer?.cancel();
      return;
    }
    final incoming = _active;
    final outgoing = _spare;
    if (outgoing == null) {
      _endCrossfade(xf);
      return;
    }
    final ms = xf.clock.elapsedMilliseconds;
    final dt = ms - xf.lastMs;
    xf.lastMs = ms;

    // Pausing freezes the fade: both songs follow the new song's play state.
    final playing = incoming.state.playing || ms < 500;
    final o = outgoing.state;
    final outgoingEnded =
        o.completed ||
        (o.duration > Duration.zero &&
            o.position >= o.duration - const Duration(milliseconds: 300));
    if (!outgoingEnded && incoming.state.playing != o.playing && ms >= 500) {
      if (incoming.state.playing) {
        unawaited(outgoing.play());
      } else {
        unawaited(outgoing.pause());
      }
    }
    if (playing) xf.linear += dt / xf.length.inMilliseconds;
    final t = xf.linear.clamp(0.0, 1.0);
    final eased = Curves.easeInOutCubic.transform(t);
    crossfadeProgress.value = eased;

    const base = 100.0;
    unawaited(incoming.setVolume(base * sin(eased * pi / 2)));
    unawaited(outgoing.setVolume(base * cos(eased * pi / 2)));
    if (xf.linear >= 1) _endCrossfade(xf);
  }

  void _endCrossfade(_Crossfade xf) {
    xf.timer?.cancel();
    xf.timer = null;
    if (!identical(_xf, xf)) return;
    _xf = null;
    final out = _spare;
    if (out != null) {
      unawaited(out.stop());
      unawaited(out.setVolume(0));
    }
    unawaited(_active.setVolume(100));
    crossfadeProgress.value = 1;
    notifyListeners();
  }

  /// Anything that takes over playback (skip, previous, a new song, close)
  /// ends a running fade on the spot and forgets a prepared one.
  void _cancelCrossfade() {
    _dropPlan();
    final xf = _xf;
    if (xf != null) _endCrossfade(xf);
  }

  // ---------------------------------------------------------------------
  // Source of the sound, used to play a song backwards while rewinding
  // ---------------------------------------------------------------------

  ({String uri, Map<String, String>? headers})? get audioSource {
    final uri = _audioSrc;
    if (uri == null) return null;
    return (uri: uri, headers: _audioHeaders);
  }

  String? _existing(String? path) =>
      path != null && File(path).existsSync() ? path : null;

  Future<_Resolved> _resolve(PlayItem item) async {
    if (item.localPath != null && File(item.localPath!).existsSync()) {
      return _Resolved(
        item.localPath!,
        _existing(item.localAudioPath),
        false,
        null,
        null,
      );
    }
    if (settings.preferDownloaded) {
      final local = downloads.byVideoId(item.videoId);
      if (local != null && File(local.filePath).existsSync()) {
        return _Resolved(
          local.filePath,
          _existing(local.audioPath),
          false,
          null,
          null,
        );
      }
    }
    final s = await YtStreams.instance.playbackSource(item.videoId);
    return _Resolved(s.video, s.audio, true, s.height, s.headers);
  }

  void _prefetchRelated(PlayItem item) {
    final id = item.videoId;
    if (_relatedFor == id && _relatedFuture != null) return;
    _relatedFor = id;
    _related = [];
    _relatedLoading = true;
    notifyListeners();
    final future = YtStreams.instance
        .related(id, title: item.title, author: item.author)
        .timeout(_relatedTimeout)
        .catchError((Object e) {
          debugPrint('[PalmTunes] Related fetch failed for $id -> $e');
          return <YtVideo>[];
        });
    _relatedFuture = future;
    future.then((list) {
      if (_relatedFor != id) return;
      _related = list;
      _relatedLoading = false;
      debugPrint('[PalmTunes] $id: ${list.length} recommendations');
      notifyListeners();
    });
  }

  YtVideo? _pickRecommendation(String currentId) {
    if (_relatedFor != currentId) return null;
    final list = _related.where((v) => v.id != currentId).toList();
    return list.where((v) => !_played.contains(v.id)).firstOrNull ??
        list.firstOrNull;
  }

  Future<bool> _playRecommended(int skip) async {
    final item = current;
    if (item == null) return false;
    var pick = _pickRecommendation(item.videoId);
    if (pick == null) {
      _prefetchRelated(item);
      final future = _relatedFuture;
      if (future == null) return false;
      _token++;
      _loading = true;
      notifyListeners();
      if (player.state.playing) unawaited(player.pause());
      await future;
      if (skip != _skipToken) return true;
      pick = _pickRecommendation(item.videoId);
      if (pick == null) {
        _relatedFuture = null;
        _relatedFor = null;
        _loading = false;
        notifyListeners();
        Notch.show(
          'No recommendations to play next',
          icon: Icons.explore_off_rounded,
        );
        return false;
      }
    }
    _played.add(pick.id);
    _queue = [..._queue.take(_index + 1), PlayItem.fromYt(pick)];
    await _playIndex(_index + 1);
    return true;
  }

  Future<void> playRecommendation(YtVideo video) async {
    if (current == null) return;
    _skipToken++;
    _played.add(video.id);
    _queue = [..._queue.take(_index + 1), PlayItem.fromYt(video)];
    await _playIndex(_index + 1);
  }

  Future<void> playQueueIndex(int i) async {
    if (i < 0 || i >= _queue.length || i == _index) return;
    _skipToken++;
    if (_shuffle) _history.add(_index);
    await _playIndex(i);
  }

  int _pickShuffle() {
    _shuffleSeen.add(_index);
    var pool = [
      for (var i = 0; i < _queue.length; i++)
        if (!_shuffleSeen.contains(i)) i,
    ];
    if (pool.isEmpty) {
      _shuffleSeen
        ..clear()
        ..add(_index);
      pool = [
        for (var i = 0; i < _queue.length; i++)
          if (i != _index) i,
      ];
    }
    return pool[_random.nextInt(pool.length)];
  }

  /// Tries the current song again from the start (after an error).
  Future<void> retryCurrent() async {
    if (_index < 0) return;
    await _playIndex(_index);
  }

  Future<void> togglePlay() => player.playOrPause();

  Future<void> play() async {
    if (current == null) return;
    await player.play();
  }

  Future<void> pause() async {
    if (current == null) return;
    await player.pause();
  }

  Future<void> next() async {
    if (_queue.isEmpty || current == null) return;
    final skip = ++_skipToken;
    if (_autoRecommend && !_shuffle) {
      if (await _playRecommended(skip)) return;
      if (skip != _skipToken) return;
    }
    if (_shuffle && _queue.length > 1) {
      final n = _pickShuffle();
      _history.add(_index);
      await _playIndex(n);
    } else if (_index < _queue.length - 1) {
      await _playIndex(_index + 1);
    }
  }

  Future<void> previous() async {
    if (player.state.position > _restartThreshold) {
      await player.seek(Duration.zero);
      return;
    }
    await previousTrack();
  }

  Future<void> previousTrack() async {
    if (current == null) return;
    _skipToken++;
    if (_shuffle && _history.isNotEmpty) {
      await _playIndex(_history.removeLast());
      return;
    }
    if (_index > 0) {
      await _playIndex(_index - 1);
      return;
    }
    await player.seek(Duration.zero);
  }

  Future<void> seekBy(Duration delta) async {
    final dur = player.state.duration;
    var target = player.state.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    await player.seek(target);
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    _shuffleSeen.clear();
    _history.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Volume: the phone's own volume (the one the side buttons change).
  // ---------------------------------------------------------------------

  StreamSubscription<double>? _volumeSub;

  /// Starts following the phone volume. Call once at start-up.
  Future<void> initDeviceVolume() async {
    try {
      await FlutterVolumeController.updateShowSystemUI(true);
    } catch (_) {}
    try {
      if (Platform.isAndroid) {
        await FlutterVolumeController.setAndroidAudioStream(
          stream: AudioStream.music,
        );
      }
    } catch (_) {}
    try {
      final v = await FlutterVolumeController.getVolume();
      if (v != null) {
        _volume = v * 100;
        _muted = v <= 0;
      }
    } catch (_) {}
    try {
      _volumeSub = FlutterVolumeController.addListener((v) {
        _volume = v * 100;
        _muted = v <= 0.001;
        notifyListeners();
      }, emitOnStart: false);
    } catch (e) {
      debugPrint('[PalmTunes] Could not follow the phone volume -> $e');
    }
    notifyListeners();
  }

  Future<void> toggleMute() async {
    try {
      await FlutterVolumeController.setMute(!_muted);
    } catch (e) {
      debugPrint('[PalmTunes] Could not mute -> $e');
    }
  }

  Future<void> setMuted(bool value) async {
    if (_muted == value) return;
    await toggleMute();
  }

  /// Moves the phone volume up or down. [delta] is in percent of the full
  /// range; on Android it snaps to the system's own volume steps.
  Future<void> changeVolume(int delta) async {
    try {
      if (delta > 0) {
        await FlutterVolumeController.raiseVolume(
          Platform.isAndroid ? null : 0.0625,
        );
      } else if (delta < 0) {
        await FlutterVolumeController.lowerVolume(
          Platform.isAndroid ? null : 0.0625,
        );
      }
    } catch (e) {
      debugPrint('[PalmTunes] Could not change the volume -> $e');
    }
  }

  Future<void> setFullscreen(bool value) async {
    if (_fullscreen == value) return;
    _fullscreen = value;
    notifyListeners();
    try {
      if (value) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.portraitUp,
        ]);
      }
    } catch (_) {}
  }

  Future<void> toggleFullscreen() => setFullscreen(!_fullscreen);

  void setPlayerOpen(bool open) {
    if (_isPlayerOpen == open) return;
    _isPlayerOpen = open;
    notifyListeners();
  }

  Future<void> close() async {
    _token++;
    _skipToken++;
    _cancelCrossfade();
    await player.stop();
    _queue = [];
    _index = -1;
    _loading = false;
    _error = null;
    _isPlayerOpen = false;
    _autoRecommend = false;
    _media = null;
    _currentHeight = null;
    _currentHasSeparateAudio = false;
    _played.clear();
    _history.clear();
    _shuffleSeen.clear();
    _relatedFuture = null;
    _relatedFor = null;
    _related = [];
    _relatedLoading = false;
    _retries = 0;
    _retrying = false;
    if (_fullscreen) await setFullscreen(false);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _volumeSub?.cancel();
    _xf?.timer?.cancel();
    _active.dispose();
    _spare?.dispose();
    crossfadeProgress.dispose();
    super.dispose();
  }
}

class _XfPlan {
  final PlayItem item;
  final int token;
  final void Function() commit;
  bool cancelled = false;
  bool ready = false;
  bool failed = false;
  _Resolved? resolved;
  Media? media;

  _XfPlan(this.item, this.token, this.commit);
}

class _Crossfade {
  final Duration length;
  final PlayItem? outgoingItem;
  final Stopwatch clock = Stopwatch();
  Timer? timer;
  double linear = 0;
  int lastMs = 0;

  _Crossfade(this.length, this.outgoingItem);
}

/// The incoming and outgoing picture of a crossfade, stacked. Without a
/// crossfade this is just the one video. Every layer is keyed by its
/// controller, so when a fade ends the picture that stays on screen is the
/// very same widget (no flash).
class CrossfadeVideo extends StatelessWidget {
  final PlayerHub hub;
  final Color fill;

  const CrossfadeVideo({
    super.key,
    required this.hub,
    this.fill = Colors.black,
  });

  Widget _layer(VideoController c, bool followFade) {
    return KeyedSubtree(
      key: ValueKey<VideoController>(c),
      child: ValueListenableBuilder<double>(
        valueListenable: hub.crossfadeProgress,
        builder: (_, v, child) => Opacity(
          opacity: followFade ? v.clamp(0.0, 1.0) : 1.0,
          child: child,
        ),
        child: Video(controller: c, controls: NoVideoControls, fill: fill),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final out = hub.outgoingController;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (out != null) _layer(out, false),
        _layer(hub.controller, out != null),
      ],
    );
  }
}
