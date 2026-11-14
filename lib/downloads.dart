import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import 'cloud_sync.dart';
import 'player_hub.dart';
import 'search.dart';
import 'ui.dart';
import 'yt_streams.dart';

enum DownloadState { none, queued, downloading, failed, done }

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = bytes.toDouble();
  var i = 0;
  while (size >= 1024 && i < units.length - 1) {
    size /= 1024;
    i++;
  }
  return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

String downloadsLabel(int count) => '$count ${count == 1 ? 'File' : 'Files'}';

class DownloadedVideo {
  final String id;
  final String videoId;
  String title;
  final String author;
  final Duration? duration;
  final String thumbnailUrl;
  String? thumbnailPath;
  String filePath;
  String? audioPath;
  final int sizeBytes;
  final String sha256;
  final bool audioOnly;
  String? categoryId;
  final DateTime addedAt;

  DownloadedVideo({
    required this.id,
    required this.videoId,
    required this.title,
    required this.author,
    required this.duration,
    required this.thumbnailUrl,
    required this.filePath,
    required this.sizeBytes,
    required this.sha256,
    this.audioPath,
    this.thumbnailPath,
    this.audioOnly = false,
    this.categoryId,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  /// What to draw for this download: the picture saved on disk when there is
  /// one, otherwise the web address.
  String get thumbSource {
    final path = thumbnailPath;
    if (path != null && File(path).existsSync()) return path;
    return thumbnailUrl;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'videoId': videoId,
    'title': title,
    'author': author,
    'durationMs': duration?.inMilliseconds,
    'thumbnailUrl': thumbnailUrl,
    'thumbnailPath': thumbnailPath,
    'filePath': filePath,
    'audioPath': audioPath,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'audioOnly': audioOnly,
    'categoryId': categoryId,
    'addedAt': addedAt.toIso8601String(),
  };

  factory DownloadedVideo.fromJson(Map<String, dynamic> j) => DownloadedVideo(
    id: j['id'] as String,
    videoId: j['videoId'] as String,
    title: j['title'] as String? ?? '',
    author: j['author'] as String? ?? '',
    duration: j['durationMs'] == null
        ? null
        : Duration(milliseconds: j['durationMs'] as int),
    thumbnailUrl: j['thumbnailUrl'] as String? ?? '',
    thumbnailPath: j['thumbnailPath'] as String?,
    filePath: j['filePath'] as String,
    audioPath: j['audioPath'] as String?,
    sizeBytes: j['sizeBytes'] as int? ?? 0,
    sha256: j['sha256'] as String? ?? '',
    audioOnly: j['audioOnly'] as bool? ?? false,
    categoryId: j['categoryId'] as String?,
    addedAt: DateTime.tryParse(j['addedAt'] as String? ?? ''),
  );
}

class VideoCategory {
  final String id;
  String name;

  VideoCategory({required this.id, required this.name});

  Map<String, dynamic> toJson() => {'id': id, 'name': name};

  factory VideoCategory.fromJson(Map<String, dynamic> j) =>
      VideoCategory(id: j['id'] as String, name: j['name'] as String? ?? '');
}

/// Lightweight read-only view of one entry in the download queue.
class DownloadQueueItem {
  final YtVideo video;
  final DownloadState state;
  final double? progress;
  final String? error;
  final DateTime? retryAt;
  final int attempts;

  const DownloadQueueItem({
    required this.video,
    required this.state,
    required this.progress,
    required this.error,
    required this.retryAt,
    required this.attempts,
  });
}

/// What was decided about the streams of a download the first time it started.
/// Kept on disk so a half-finished download can continue after a restart, and
/// so the partial files are only reused when the stream is the same one.
class _TaskMeta {
  final String dir;
  final int videoLength;
  final int audioLength;
  final bool videoMp4;
  final bool audioMp4;

  const _TaskMeta({
    required this.dir,
    required this.videoLength,
    required this.audioLength,
    required this.videoMp4,
    required this.audioMp4,
  });

  factory _TaskMeta.fromSource(DownloadSource s, String dir) => _TaskMeta(
    dir: dir,
    videoLength: s.videoLength,
    audioLength: s.audioLength,
    videoMp4: s.videoMp4,
    audioMp4: s.audioMp4,
  );

  int get total => videoLength + audioLength;
  String get mergedExt => videoMp4 && audioMp4 ? 'mp4' : 'mkv';
  String get videoExt => videoMp4 ? 'mp4' : 'webm';
  String get audioExt => audioMp4 ? 'm4a' : 'webm';

  bool sameFormat(_TaskMeta o) =>
      videoLength == o.videoLength &&
      audioLength == o.audioLength &&
      videoMp4 == o.videoMp4 &&
      audioMp4 == o.audioMp4;

  Map<String, dynamic> toJson() => {
    'dir': dir,
    'videoLength': videoLength,
    'audioLength': audioLength,
    'videoMp4': videoMp4,
    'audioMp4': audioMp4,
  };

  factory _TaskMeta.fromJson(Map<String, dynamic> j) => _TaskMeta(
    dir: j['dir'] as String,
    videoLength: j['videoLength'] as int? ?? 0,
    audioLength: j['audioLength'] as int? ?? 0,
    videoMp4: j['videoMp4'] as bool? ?? true,
    audioMp4: j['audioMp4'] as bool? ?? true,
  );
}

class _DownloadTask {
  final YtVideo video;
  final DateTime addedAt;
  DownloadState state;
  double? progress;
  String? error;
  DateTime? retryAt;
  int attempts = 0;
  _TaskMeta? meta;

  bool cancelled = false;
  bool preempted = false;
  bool aborted = false;
  bool announced = false;
  bool failureAnnounced = false;

  final List<StreamSubscription<List<int>>> subs = [];
  final List<VoidCallback> stoppers = [];
  Process? process;

  _DownloadTask(
    this.video, {
    this.state = DownloadState.queued,
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  void resetRuntime() {
    subs.clear();
    stoppers.clear();
    process = null;
    aborted = false;
  }

  void abort() {
    aborted = true;
    for (final s in subs) {
      s.cancel();
    }
    for (final stop in stoppers) {
      stop();
    }
    process?.kill();
  }

  Map<String, dynamic> toJson() => {
    'video': video.toJson(),
    // A download that was running when the app closed simply resumes.
    'state': state == DownloadState.downloading
        ? DownloadState.queued.name
        : state.name,
    'error': error,
    'attempts': attempts,
    'meta': meta?.toJson(),
    'addedAt': addedAt.toIso8601String(),
  };

  factory _DownloadTask.fromJson(Map<String, dynamic> j) {
    final stateName = j['state'] as String? ?? 'queued';
    final state = stateName == DownloadState.failed.name
        ? DownloadState.failed
        : DownloadState.queued;
    final t = _DownloadTask(
      YtVideo.fromJson(Map<String, dynamic>.from(j['video'] as Map)),
      state: state,
      addedAt: DateTime.tryParse(j['addedAt'] as String? ?? ''),
    );
    t.error = j['error'] as String?;
    t.attempts = j['attempts'] as int? ?? 0;
    final m = j['meta'];
    if (m is Map) t.meta = _TaskMeta.fromJson(Map<String, dynamic>.from(m));
    return t;
  }
}

class DownloadsStore extends ChangeNotifier {
  static const Duration _connectTimeout = Duration(seconds: 45);
  static const Duration _stallTimeout = Duration(seconds: 60);
  static const Duration retryEvery = Duration(seconds: 10);
  static const int _chunkBytes = 4 * 1024 * 1024;
  static const int _chunkRetries = 5;

  final List<DownloadedVideo> _videos = [];
  final List<VideoCategory> _categories = [];

  /// Insertion ordered: the first entry is the next one to download.
  final Map<String, _DownloadTask> _tasks = {};
  String? _customDir;
  File? _dbFile;
  Future<void> _saveChain = Future.value();
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Future<String?>? _ffmpegLookup;
  Timer? _retryTimer;
  bool _started = false;
  bool _disposed = false;

  List<DownloadedVideo> get videos => List.unmodifiable(_videos);
  List<VideoCategory> get categories => List.unmodifiable(_categories);
  List<YtVideo> get activeDownloads =>
      _tasks.values.map((t) => t.video).toList();
  List<DownloadQueueItem> get queueItems => [
    for (final t in _tasks.values)
      DownloadQueueItem(
        video: t.video,
        state: t.state,
        progress: t.progress,
        error: t.error,
        retryAt: t.retryAt,
        attempts: t.attempts,
      ),
  ];
  int get activeDownloadCount => _tasks.length;
  int get totalBytes => _videos.fold(0, (a, v) => a + v.sizeBytes);
  String? get customDirectory => _customDir;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  Future<void> load() async {
    final dir = await getApplicationSupportDirectory();
    _dbFile = File(p.join(dir.path, 'palm_tunes_library.json'));
    if (await _dbFile!.exists()) {
      try {
        final data =
            jsonDecode(await _dbFile!.readAsString()) as Map<String, dynamic>;
        _customDir = data['downloadDir'] as String?;
        _categories
          ..clear()
          ..addAll(
            (data['categories'] as List? ?? []).map(
              (e) =>
                  VideoCategory.fromJson(Map<String, dynamic>.from(e as Map)),
            ),
          );
        _videos
          ..clear()
          ..addAll(
            (data['videos'] as List? ?? []).map(
              (e) =>
                  DownloadedVideo.fromJson(Map<String, dynamic>.from(e as Map)),
            ),
          );
        final docs = (await getApplicationDocumentsDirectory()).path;
        String? rebase(String? path) {
          if (path == null || File(path).existsSync()) return path;
          const lib = '/Palm Tunes/';
          final i = path.indexOf(lib);
          if (i >= 0) {
            final c = p.join(
              docs,
              'Palm Tunes',
              path.substring(i + lib.length),
            );
            if (File(c).existsSync()) return c;
          }
          const thumbs = '/thumbnails/';
          final j = path.indexOf(thumbs);
          if (j >= 0) {
            final c = p.join(
              dir.path,
              'thumbnails',
              path.substring(j + thumbs.length),
            );
            if (File(c).existsSync()) return c;
          }
          return path;
        }

        for (final v in _videos) {
          v.filePath = rebase(v.filePath) ?? v.filePath;
          v.audioPath = rebase(v.audioPath);
          v.thumbnailPath = rebase(v.thumbnailPath);
        }
        _videos.removeWhere((v) => !File(v.filePath).existsSync());
        for (final v in _videos) {
          final a = v.audioPath;
          if (a != null && !File(a).existsSync()) v.audioPath = null;
        }
        final ids = _categories.map((c) => c.id).toSet();
        for (final v in _videos) {
          if (v.categoryId != null && !ids.contains(v.categoryId)) {
            v.categoryId = null;
          }
        }
        _tasks.clear();
        for (final e in (data['queue'] as List? ?? [])) {
          try {
            final t = _DownloadTask.fromJson(
              Map<String, dynamic>.from(e as Map),
            );
            if (_videos.any((v) => v.videoId == t.video.id)) continue;
            if (t.state == DownloadState.failed) {
              t.retryAt = DateTime.now().add(retryEvery);
            }
            t.progress = _savedProgress(t);
            _tasks[t.video.id] = t;
          } catch (err) {
            debugPrint('[PalmTunes] Skipped a saved download -> $err');
          }
        }
      } catch (e) {
        debugPrint('[PalmTunes] Library load failed -> $e');
      }
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Thumbnails
  // ---------------------------------------------------------------------

  bool _backfilling = false;

  Future<Directory> _thumbDirectory() async {
    final base =
        _dbFile?.parent.path ?? (await getApplicationSupportDirectory()).path;
    final d = Directory(p.join(base, 'thumbnails'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Saves the picture of a video next to the library so it still shows when
  /// the web copy is gone or there is no internet. Null when it can't be got.
  Future<String?> _saveThumbnail(String videoId, String url) async {
    final urls = <String>{
      if (url.startsWith('http')) url,
      'https://i.ytimg.com/vi/$videoId/hqdefault.jpg',
      'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
    };
    final dir = await _thumbDirectory();
    final target = File(p.join(dir.path, '$videoId.jpg'));
    for (final u in urls) {
      try {
        final res = await http
            .get(Uri.parse(u))
            .timeout(const Duration(seconds: 20));
        // YouTube answers a missing picture with a tiny grey placeholder.
        if (res.statusCode != 200 || res.bodyBytes.length < 2000) continue;
        await target.writeAsBytes(res.bodyBytes, flush: true);
        return target.path;
      } catch (_) {}
    }
    return null;
  }

  /// Gives every download that has no saved picture one, in the background.
  /// Downloads made before thumbnails were saved get theirs the first time
  /// this runs with internet. It gives up after a few misses in a row (for
  /// example when offline) and tries again at the next start.
  Future<void> backfillThumbnails() async {
    if (_backfilling || _disposed) return;
    _backfilling = true;
    var misses = 0;
    var saved = 0;
    try {
      for (final v in List<DownloadedVideo>.of(_videos)) {
        if (_disposed) break;
        final have = v.thumbnailPath;
        if (have != null && File(have).existsSync()) continue;
        final path = await _saveThumbnail(v.videoId, v.thumbnailUrl);
        if (path == null) {
          if (++misses >= 3) break;
          continue;
        }
        misses = 0;
        if (!_videos.contains(v)) {
          await _safeDelete(File(path));
          continue;
        }
        v.thumbnailPath = path;
        saved++;
        notifyListeners();
        if (saved % 10 == 0) _save();
      }
    } catch (e) {
      debugPrint('[PalmTunes] Thumbnail backfill stopped -> $e');
    } finally {
      _backfilling = false;
    }
    if (saved > 0) _save();
  }

  /// Starts working through the queue. Called once the app is fully set up
  /// (cookies loaded), so downloads that were interrupted by closing the app
  /// pick up exactly where they stopped.
  void resumeQueue() {
    _started = true;
    _retryTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickRetries(),
    );
    _pump();
    unawaited(backfillThumbnails());
  }

  double? _savedProgress(_DownloadTask t) {
    final m = t.meta;
    if (m == null || m.total <= 0) return null;
    var have = 0;
    for (final kind in const ['video', 'audio']) {
      final f = File(_partPath(m.dir, t.video.id, kind));
      if (f.existsSync()) have += f.lengthSync();
    }
    return (have / m.total).clamp(0.0, 1.0);
  }

  void _save() {
    final f = _dbFile;
    if (f == null) return;
    final data = jsonEncode({
      'downloadDir': _customDir,
      'categories': _categories.map((c) => c.toJson()).toList(),
      'videos': _videos.map((v) => v.toJson()).toList(),
      'queue': _tasks.values.map((t) => t.toJson()).toList(),
    });
    _saveChain = _saveChain
        .then((_) => f.writeAsString(data, flush: true))
        .catchError((Object _) => f);
  }

  void _commit() {
    notifyListeners();
    _save();
  }

  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds >= 120) {
      _lastNotify = now;
      notifyListeners();
    }
  }

  Future<Directory> downloadDirectory() async {
    final base =
        _customDir ??
        p.join((await getApplicationDocumentsDirectory()).path, 'Palm Tunes');
    final d = Directory(base);
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  void setDownloadDirectory(String? path) {
    _customDir = (path == null || path.trim().isEmpty) ? null : path.trim();
    _commit();
  }

  DownloadState stateOf(String videoId) {
    final t = _tasks[videoId];
    if (t != null) return t.state;
    return _videos.any((v) => v.videoId == videoId)
        ? DownloadState.done
        : DownloadState.none;
  }

  double? progressOf(String videoId) => _tasks[videoId]?.progress;

  DownloadedVideo? byVideoId(String videoId) =>
      _videos.where((v) => v.videoId == videoId).firstOrNull;

  VideoCategory? categoryById(String id) =>
      _categories.where((c) => c.id == id).firstOrNull;

  List<DownloadedVideo> videosIn(String? categoryId) =>
      _videos.where((v) => v.categoryId == categoryId).toList();

  int countIn(String? categoryId) =>
      _videos.where((v) => v.categoryId == categoryId).length;

  Future<String?> ffmpegPath() => _ffmpegPath();

  Future<String?> _ffmpegPath() => _ffmpegLookup ??= _findFfmpeg();

  /// Phones have no ffmpeg binary, so downloads keep the video and audio
  /// streams as two files and the player plays them together.
  Future<String?> _findFfmpeg() async => null;

  // ---------------------------------------------------------------------
  // Queue
  // ---------------------------------------------------------------------

  String _partPath(String dir, String id, String kind) =>
      p.join(dir, '.$id.$kind.part');

  /// Adds a video to the end of the queue. Returns right away; the queue
  /// downloads one item at a time and reports through the notch.
  Future<String?> startDownload(YtVideo video) async {
    final queued = _tasks[video.id];
    if (queued != null) {
      if (queued.state == DownloadState.failed) retryDownload(video.id);
      return null;
    }
    final existing = byVideoId(video.id);
    if (existing != null) {
      if (await File(existing.filePath).exists()) {
        return 'Already in downloads as "${existing.title}"';
      }
      _videos.remove(existing);
    }
    if (_tasks.containsKey(video.id)) return null;
    _tasks[video.id] = _DownloadTask(video);
    _commit();
    _pump();
    return null;
  }

  /// Retries a failed download right now instead of waiting for the timer.
  void retryDownload(String videoId) {
    final t = _tasks[videoId];
    if (t == null || t.state != DownloadState.failed) return;
    t.state = DownloadState.queued;
    t.retryAt = null;
    _commit();
    _pump();
  }

  void cancelDownload(String videoId) {
    final t = _tasks[videoId];
    if (t == null) return;
    final running = t.state == DownloadState.downloading;
    t.cancelled = true;
    t.abort();
    _tasks.remove(videoId);
    _commit();
    // A running task cleans its own files once it has let go of them.
    if (!running) unawaited(_deletePartFiles(t));
    _pump();
  }

  /// Moves a queue entry. Dropping something on the very top makes it the
  /// priority: the running download is parked (its progress is kept) and the
  /// moved one starts straight away.
  void reorderQueue(int oldIndex, int newIndex) {
    final entries = _tasks.entries.toList();
    if (oldIndex < 0 || oldIndex >= entries.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    newIndex = newIndex.clamp(0, entries.length - 1);
    if (newIndex == oldIndex) return;
    final moved = entries.removeAt(oldIndex);
    entries.insert(newIndex, moved);
    _tasks
      ..clear()
      ..addEntries(entries);

    // Something that is waiting now sits above the running download (or the
    // running one was pushed below it): park the running one so the item the
    // user put first starts straight away. Its progress stays on disk.
    final order = entries.map((e) => e.value).toList();
    final runningIdx = order.indexWhere(
      (t) => t.state == DownloadState.downloading,
    );
    if (runningIdx != -1) {
      final running = order[runningIdx];
      final movedTask = moved.value;
      _DownloadTask? winner;
      if (!identical(movedTask, running)) {
        if (newIndex < runningIdx) winner = movedTask;
      } else {
        winner = order
            .take(runningIdx)
            .where((t) => t.state == DownloadState.queued)
            .firstOrNull;
      }
      if (winner != null) {
        if (winner.state == DownloadState.failed) {
          winner.state = DownloadState.queued;
          winner.retryAt = null;
        }
        running.preempted = true;
        running.abort();
      }
    }
    _commit();
    _pump();
  }

  void _tickRetries() {
    var changed = false;
    final now = DateTime.now();
    for (final t in _tasks.values) {
      if (t.state != DownloadState.failed) continue;
      final at = t.retryAt;
      if (at != null && !now.isBefore(at)) {
        t.state = DownloadState.queued;
        t.retryAt = null;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _pump();
    }
  }

  void _pump() {
    if (!_started || _disposed) return;
    if (_tasks.values.any((t) => t.state == DownloadState.downloading)) return;
    final next = _tasks.values
        .where((t) => t.state == DownloadState.queued)
        .firstOrNull;
    if (next != null) unawaited(_runTask(next));
  }

  String _describeError(Object e) {
    if (e is TimeoutException) return 'Connection timed out';
    if (e is SocketException || e is http.ClientException) {
      return 'Network connection lost';
    }
    if (e is HttpException) return e.message;
    if (e is FileSystemException) return 'Could not write to the disk';
    return 'Download failed';
  }

  Future<void> _runTask(_DownloadTask task) async {
    task.state = DownloadState.downloading;
    task.error = null;
    task.retryAt = null;
    task.resetRuntime();
    notifyListeners();
    if (!task.announced) {
      task.announced = true;
      Notch.show(
        '${task.video.title} is Downloading',
        icon: Icons.downloading_rounded,
      );
    }

    var completed = false;
    String? failure;
    try {
      completed = await _download(task);
    } on YtFriendlyError catch (e) {
      failure = e.message;
    } catch (e) {
      debugPrint('[PalmTunes] Download failed for ${task.video.id} -> $e');
      YtStreams.instance.invalidate(task.video.id);
      failure = _describeError(e);
    }
    task.abort();

    if (completed) {
      _tasks.remove(task.video.id);
    } else if (task.cancelled) {
      await _deletePartFiles(task);
    } else if (task.preempted) {
      task.preempted = false;
      task.state = DownloadState.queued;
    } else {
      task.state = DownloadState.failed;
      task.attempts++;
      task.error = failure ?? 'Download interrupted';
      task.retryAt = DateTime.now().add(retryEvery);
      if (!task.failureAnnounced) {
        task.failureAnnounced = true;
        Notch.show(
          '${task.video.title} failed, retrying in ${retryEvery.inSeconds}s',
          icon: Icons.error_outline_rounded,
        );
      }
    }
    _commit();
    _pump();
  }

  Future<int> _existingLength(File f, int expected) async {
    if (!await f.exists()) return 0;
    final n = await f.length();
    // Only a stream of known size can be continued; anything odd starts over.
    if (expected <= 0 || n > expected) {
      await _safeDelete(f);
      return 0;
    }
    return n;
  }

  Future<bool> _partsComplete(_TaskMeta m, String id) async {
    if (m.videoLength <= 0 || m.audioLength <= 0) return false;
    final v = File(_partPath(m.dir, id, 'video'));
    final a = File(_partPath(m.dir, id, 'audio'));
    if (!await v.exists() || !await a.exists()) return false;
    return await v.length() == m.videoLength &&
        await a.length() == m.audioLength;
  }

  Future<void> _deletePartFiles(_DownloadTask t) async {
    final m = t.meta;
    if (m == null) return;
    await _safeDelete(File(_partPath(m.dir, t.video.id, 'video')));
    await _safeDelete(File(_partPath(m.dir, t.video.id, 'audio')));
    await _safeDelete(
      File(p.join(m.dir, '.${t.video.id}.merge.${m.mergedExt}')),
    );
  }

  /// Runs one attempt. Returns true when the video was fully saved, false when
  /// the attempt was cancelled / parked. Throws when it failed; whatever was
  /// already downloaded stays on disk so the next attempt continues from it.
  Future<bool> _download(_DownloadTask task) async {
    final video = task.video;

    _TaskMeta m;
    DownloadSource? src;
    final old = task.meta;
    if (old != null && await _partsComplete(old, video.id)) {
      // Everything is already on disk (closed during the merge): no network.
      m = old;
    } else {
      src = await YtStreams.instance.downloadSource(video.id);
      if (task.cancelled || task.preempted) return false;
      final dirPath = old?.dir ?? (await downloadDirectory()).path;
      final fresh = _TaskMeta.fromSource(src, dirPath);
      if (old != null && !old.sameFormat(fresh)) {
        debugPrint(
          '[PalmTunes] ${video.id}: stream changed, starting this download over',
        );
        await _deletePartFiles(task);
      }
      m = (old != null && old.sameFormat(fresh)) ? old : fresh;
      task.meta = m;
      _save();
    }

    final dir = Directory(m.dir);
    if (!await dir.exists()) await dir.create(recursive: true);
    final videoPart = File(_partPath(m.dir, video.id, 'video'));
    final audioPart = File(_partPath(m.dir, video.id, 'audio'));
    final merged = File(p.join(m.dir, '.${video.id}.merge.${m.mergedExt}'));
    await _safeDelete(merged);

    if (src != null) {
      var received =
          await _existingLength(videoPart, m.videoLength) +
          await _existingLength(audioPart, m.audioLength);
      final total = m.total;
      task.progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0;
      notifyListeners();

      void onBytes(int n) {
        received += n;
        task.progress = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
        _notifyThrottled();
      }

      Object? failure;
      Future<void> guard(Future<void> f) => f.catchError((Object e) {
        failure ??= e;
        task.abort();
      });

      await Future.wait([
        guard(
          _fetchTo(
            task,
            src.videoUrl,
            m.videoLength,
            src.headers,
            videoPart,
            onBytes,
          ),
        ),
        guard(
          _fetchTo(
            task,
            src.audioUrl,
            m.audioLength,
            src.headers,
            audioPart,
            onBytes,
          ),
        ),
      ]);

      if (task.cancelled || task.preempted) return false;
      if (failure != null) throw failure!;
    }
    if (task.cancelled || task.preempted) return false;

    final videoSize = await videoPart.exists() ? await videoPart.length() : 0;
    final audioSize = await audioPart.exists() ? await audioPart.length() : 0;
    if (videoSize == 0 || audioSize == 0) {
      throw StateError('Downloaded stream is empty');
    }
    if ((m.videoLength > 0 && videoSize != m.videoLength) ||
        (m.audioLength > 0 && audioSize != m.audioLength)) {
      throw const HttpException('Stream ended early');
    }

    task.progress = null;
    notifyListeners();

    final didMerge = await _merge(
      task,
      videoPart,
      audioPart,
      merged,
      m.mergedExt == 'mp4',
    );
    if (task.cancelled || task.preempted) return false;

    final primary = didMerge ? merged : videoPart;
    final hash = (await sha256.bind(primary.openRead()).first).toString();
    final dup = _videos.where((v) => v.sha256 == hash).firstOrNull;
    if (dup != null) {
      await _deletePartFiles(task);
      Notch.show(
        'Same file already in downloads as "${dup.title}"',
        icon: Icons.info_outline_rounded,
      );
      return true;
    }

    final base = _sanitize(video.title);
    late final File file;
    String? audioPath;
    if (didMerge) {
      final target = await _uniquePath(m.dir, base, m.mergedExt);
      file = await merged.rename(target);
    } else {
      final target = await _uniquePath(m.dir, base, m.videoExt);
      file = await videoPart.rename(target);
      final audioTarget = await _uniquePath(
        m.dir,
        '${p.basenameWithoutExtension(target)}.audio',
        m.audioExt,
      );
      audioPath = (await audioPart.rename(audioTarget)).path;
    }
    await _deletePartFiles(task);

    var size = await file.length();
    if (audioPath != null) size += await File(audioPath).length();

    String? thumbPath;
    try {
      thumbPath = await _saveThumbnail(video.id, video.thumbnailUrl);
    } catch (_) {}

    _videos.insert(
      0,
      DownloadedVideo(
        id: const Uuid().v4(),
        videoId: video.id,
        title: video.title,
        author: video.author,
        duration: video.duration,
        thumbnailUrl: video.thumbnailUrl,
        thumbnailPath: thumbPath,
        filePath: file.path,
        audioPath: audioPath,
        sizeBytes: size,
        sha256: hash,
      ),
    );
    debugPrint(
      '[PalmTunes] Downloaded ${video.id} -> ${file.path}${audioPath != null ? ' + $audioPath' : ''}',
    );
    Notch.show(
      '${video.title} is Downloaded',
      icon: Icons.download_done_rounded,
    );
    return true;
  }

  /// Ranged download that can start part way through a file and survives
  /// dropped connections: a chunk that fails is retried (with a growing wait)
  /// from exactly the byte it stopped at.
  Stream<List<int>> _openRangedFrom(
    String url,
    int length,
    Map<String, String> headers,
    int startAt,
    bool Function() stopped,
  ) async* {
    final client = http.Client();
    try {
      if (length <= 0) {
        final req = http.Request('GET', Uri.parse(url))
          ..headers.addAll(headers);
        final res = await client.send(req).timeout(_connectTimeout);
        if (res.statusCode != 200 && res.statusCode != 206) {
          throw HttpException('HTTP ${res.statusCode}');
        }
        yield* res.stream.timeout(_stallTimeout);
        return;
      }
      var start = startAt;
      var failures = 0;
      while (start < length) {
        if (stopped()) return;
        final end = min(start + _chunkBytes, length) - 1;
        final before = start;
        try {
          final req = http.Request('GET', Uri.parse(url))
            ..headers.addAll({...headers, 'Range': 'bytes=$start-$end'});
          final res = await client.send(req).timeout(_connectTimeout);
          if (res.statusCode != 206) {
            unawaited(res.stream.drain<void>().catchError((Object _) {}));
            throw HttpException('HTTP ${res.statusCode}');
          }
          await for (final chunk in res.stream.timeout(_stallTimeout)) {
            start += chunk.length;
            yield chunk;
          }
          if (start == before) throw const HttpException('Empty chunk');
          failures = 0;
        } catch (e) {
          if (stopped()) return;
          failures++;
          debugPrint(
            '[PalmTunes] Chunk at $start failed ($failures/$_chunkRetries) -> ${e.toString().split('\n').first}',
          );
          if (failures > _chunkRetries) rethrow;
          await Future.delayed(Duration(seconds: min(8, 1 << (failures - 1))));
        }
      }
    } finally {
      client.close();
    }
  }

  Future<void> _fetchTo(
    _DownloadTask task,
    String url,
    int length,
    Map<String, String> headers,
    File part,
    void Function(int) onBytes,
  ) async {
    final have = await _existingLength(part, length);
    if (length > 0 && have >= length) return;
    final sink = part.openWrite(
      mode: have > 0 ? FileMode.append : FileMode.write,
    );
    final completer = Completer<void>();
    task.stoppers.add(() {
      if (!completer.isCompleted) completer.complete();
    });
    final sub = _openRangedFrom(url, length, headers, have, () => task.aborted)
        .listen(
          (chunk) {
            sink.add(chunk);
            onBytes(chunk.length);
          },
          onError: (Object e) {
            if (!completer.isCompleted) completer.completeError(e);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete();
          },
          cancelOnError: true,
        );
    task.subs.add(sub);
    try {
      await completer.future;
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  Future<bool> _merge(
    _DownloadTask task,
    File video,
    File audio,
    File out,
    bool mp4,
  ) async {
    final ffmpeg = await _ffmpegPath();
    if (ffmpeg == null || task.cancelled || task.preempted) return false;
    try {
      final proc = await Process.start(ffmpeg, [
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        video.path,
        '-i',
        audio.path,
        '-map',
        '0:v:0',
        '-map',
        '1:a:0',
        '-c',
        'copy',
        if (mp4) ...['-movflags', '+faststart'],
        out.path,
      ]);
      task.process = proc;
      final err = StringBuffer();
      final outDone = proc.stdout.drain<void>();
      final errDone = proc.stderr
          .transform(utf8.decoder)
          .listen(err.write)
          .asFuture<void>();
      final code = await proc.exitCode;
      await Future.wait([outDone, errDone]).catchError((Object _) => []);
      task.process = null;
      if (code != 0) {
        if (!task.cancelled && !task.preempted) {
          debugPrint(
            '[PalmTunes] ffmpeg exited $code -> ${err.toString().trim()}',
          );
        }
        await _safeDelete(out);
        return false;
      }
      return await out.exists() && await out.length() > 0;
    } catch (e) {
      debugPrint('[PalmTunes] ffmpeg failed -> $e');
      task.process = null;
      await _safeDelete(out);
      return false;
    }
  }

  Future<String?> renameVideo(String id, String newTitle) async {
    final v = _videos.where((e) => e.id == id).firstOrNull;
    if (v == null) return 'Download not found';
    final clean = newTitle.trim();
    if (clean.isEmpty) return 'Name cannot be empty';
    final base = _sanitize(clean);
    if (p.basenameWithoutExtension(v.filePath) != base) {
      final ext = p.extension(v.filePath).replaceFirst('.', '');
      final target = await _uniquePath(
        p.dirname(v.filePath),
        base,
        ext.isEmpty ? 'mp4' : ext,
      );
      try {
        final f = await File(v.filePath).rename(target);
        v.filePath = f.path;
      } catch (_) {
        return 'Could not rename the file. It may be in use.';
      }
      final audio = v.audioPath;
      if (audio != null && await File(audio).exists()) {
        final audioExt = p.extension(audio).replaceFirst('.', '');
        final audioTarget = await _uniquePath(
          p.dirname(v.filePath),
          '${p.basenameWithoutExtension(v.filePath)}.audio',
          audioExt.isEmpty ? 'm4a' : audioExt,
        );
        try {
          final a = await File(audio).rename(audioTarget);
          v.audioPath = a.path;
        } catch (_) {}
      }
    }
    v.title = clean;
    _commit();
    return null;
  }

  Future<void> _deleteFiles(DownloadedVideo v) async {
    await _safeDelete(File(v.filePath));
    final a = v.audioPath;
    if (a != null) await _safeDelete(File(a));
    final t = v.thumbnailPath;
    if (t != null) await _safeDelete(File(t));
  }

  Future<void> deleteVideo(String id) async {
    final v = _videos.where((e) => e.id == id).firstOrNull;
    if (v == null) return;
    await _deleteFiles(v);
    _videos.remove(v);
    _commit();
  }

  Future<void> deleteAllDownloads() async {
    for (final id in _tasks.keys.toList()) {
      cancelDownload(id);
    }
    for (final v in _videos) {
      await _deleteFiles(v);
    }
    _videos.clear();
    _commit();
  }

  /// Puts [draggedId] where [targetId] is (below it when moving down, above it
  /// when moving up). Only songs of the same playlist can be reordered.
  void reorderVideo(String draggedId, String targetId) {
    if (draggedId == targetId) return;
    final from = _videos.indexWhere((v) => v.id == draggedId);
    final to = _videos.indexWhere((v) => v.id == targetId);
    if (from == -1 || to == -1) return;
    if (_videos[from].categoryId != _videos[to].categoryId) return;
    final item = _videos.removeAt(from);
    _videos.insert(to, item);
    _commit();
  }

  void moveToCategory(String videoEntryId, String? categoryId) {
    final v = _videos.where((e) => e.id == videoEntryId).firstOrNull;
    if (v == null || v.categoryId == categoryId) return;
    v.categoryId = categoryId;
    _commit();
  }

  bool categoryNameExists(String name, {String? exceptId}) {
    final n = name.trim().toLowerCase();
    return n == 'all' ||
        _categories.any(
          (c) => c.id != exceptId && c.name.trim().toLowerCase() == n,
        );
  }

  VideoCategory addCategory(String name) {
    final c = VideoCategory(id: const Uuid().v4(), name: name.trim());
    _categories.add(c);
    _commit();
    return c;
  }

  void renameCategory(String id, String name) {
    final c = categoryById(id);
    if (c == null) return;
    c.name = name.trim();
    _commit();
  }

  Future<void> deleteCategory(String id, {required bool deleteVideos}) async {
    final inCat = _videos.where((v) => v.categoryId == id).toList();
    for (final v in inCat) {
      if (deleteVideos) {
        await _deleteFiles(v);
        _videos.remove(v);
      } else {
        v.categoryId = null;
      }
    }
    _categories.removeWhere((c) => c.id == id);
    _commit();
  }

  void reorderCategory(String draggedId, String targetId) {
    final from = _categories.indexWhere((c) => c.id == draggedId);
    final to = _categories.indexWhere((c) => c.id == targetId);
    if (from == -1 || to == -1 || from == to) return;
    final c = _categories.removeAt(from);
    _categories.insert(to, c);
    _commit();
  }

  Future<void> _safeDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<String> _uniquePath(String dir, String base, String ext) async {
    var candidate = p.join(dir, '$base.$ext');
    var n = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(dir, '$base ($n).$ext');
      n++;
    }
    return candidate;
  }

  String _sanitize(String name) {
    var s = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (s.length > 120) s = s.substring(0, 120).trim();
    return s.isEmpty ? 'video' : s;
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    // Park running downloads instead of cancelling them, so nothing already
    // downloaded is thrown away.
    for (final t in _tasks.values) {
      t.preempted = true;
      t.abort();
    }
    super.dispose();
  }
}

// ===========================================================================
// Screen
// ===========================================================================

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  static const double _fade = 10;

  String? _selected;
  bool _queueOpen = true;
  final _draggingVideo = ValueNotifier<bool>(false);
  final _barScroll = ScrollController();
  final _listScroll = ScrollController();
  final _listKey = GlobalKey();
  Offset? _dragPos;
  Timer? _autoScroll;

  @override
  void initState() {
    super.initState();
    _draggingVideo.addListener(_onDragState);
  }

  @override
  void dispose() {
    _draggingVideo.removeListener(_onDragState);
    _autoScroll?.cancel();
    _draggingVideo.dispose();
    _barScroll.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  // While a song is being dragged, holding it near the top or bottom edge of
  // the list scrolls the list so long playlists can be reordered.
  void _onDragState() {
    if (_draggingVideo.value) {
      _autoScroll ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _tickAutoScroll(),
      );
    } else {
      _autoScroll?.cancel();
      _autoScroll = null;
      _dragPos = null;
    }
  }

  void _tickAutoScroll() {
    final pos = _dragPos;
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (pos == null || box == null || !box.attached) return;
    if (!_listScroll.hasClients) return;
    final local = box.globalToLocal(pos);
    if (local.dx < 0 || local.dx > box.size.width) return;
    const edge = 70.0;
    var delta = 0.0;
    if (local.dy >= 0 && local.dy < edge) {
      delta = -((edge - local.dy) / edge).clamp(0.0, 1.0) * 16;
    } else if (local.dy > box.size.height - edge &&
        local.dy <= box.size.height) {
      delta =
          ((local.dy - (box.size.height - edge)) / edge).clamp(0.0, 1.0) * 16;
    }
    if (delta == 0) return;
    final sp = _listScroll.position;
    sp.jumpTo((sp.pixels + delta).clamp(0.0, sp.maxScrollExtent));
  }

  Future<void> _createCategory() async {
    final name = await _promptName(
      context,
      title: 'New playlist',
      hint: 'Playlist name',
      confirmLabel: 'Create',
    );
    if (name == null || !mounted) return;
    final store = context.read<DownloadsStore>();
    if (store.categoryNameExists(name)) {
      Notch.show(
        'A playlist named "$name" already exists',
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    final c = store.addCategory(name);
    setState(() => _selected = c.id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_barScroll.hasClients) {
        _barScroll.animateTo(
          _barScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _categoryMenu(VideoCategory c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _Sheet(
        title: c.name,
        children: [
          _SheetTile(
            Icons.edit_rounded,
            'Rename playlist',
            () => Navigator.pop(ctx, 'rename'),
          ),
          _SheetTile(
            Icons.delete_outline_rounded,
            'Delete playlist',
            () => Navigator.pop(ctx, 'delete'),
            danger: true,
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    final store = context.read<DownloadsStore>();
    if (action == 'rename') {
      final name = await _promptName(
        context,
        title: 'Rename playlist',
        hint: 'Playlist name',
        initial: c.name,
        confirmLabel: 'Rename',
      );
      if (name == null || name == c.name || !mounted) return;
      if (store.categoryNameExists(name, exceptId: c.id)) {
        Notch.show(
          'A playlist named "$name" already exists',
          icon: Icons.error_outline_rounded,
        );
        return;
      }
      store.renameCategory(c.id, name);
    } else {
      final count = store.countIn(c.id);
      var withVideos = false;
      if (count > 0) {
        final choice = await showDialog<_CategoryDeleteChoice>(
          context: context,
          builder: (ctx) => _DeleteCategoryDialog(name: c.name, count: count),
        );
        if (choice == null || !mounted) return;
        withVideos = choice == _CategoryDeleteChoice.withVideos;
      }
      await store.deleteCategory(c.id, deleteVideos: withVideos);
      if (mounted && _selected == c.id) setState(() => _selected = null);
    }
  }

  Future<void> _renameSong(DownloadedVideo v) async {
    final store = context.read<DownloadsStore>();
    final name = await _promptName(
      context,
      title: 'Rename song',
      hint: 'Song name',
      initial: v.title,
      confirmLabel: 'Rename',
    );
    if (name == null || name == v.title || !mounted) return;
    final err = await store.renameVideo(v.id, name);
    if (err != null) Notch.show(err, icon: Icons.error_outline_rounded);
  }

  Future<void> _deleteSong(DownloadedVideo v) async {
    final cloud = context.read<CloudSyncStore>();
    final store = context.read<DownloadsStore>();
    if (cloud.canOfferCloudDelete(v.videoId)) {
      final choice = await _askDeleteChoice(context, v);
      if (choice == _DeleteChoice.cancel || !mounted) return;
      // The file goes first, so the song is never uploaded again in between.
      await store.deleteVideo(v.id);
      if (choice == _DeleteChoice.deviceAndCloud) {
        await cloud.removeFromCloud(v.videoId);
      }
      return;
    }
    final ok = await confirmDelete(
      context,
      title: 'Delete download?',
      message: '"${v.title}" will be removed from this phone.',
    );
    if (ok) await store.deleteVideo(v.id);
  }

  Future<void> _downloadCloudSong(CloudSong s) async {
    final msg = await context.read<CloudSyncStore>().downloadGhost(s);
    if (!mounted) return;
    if (msg != null) {
      Notch.show(msg, icon: Icons.info_outline_rounded);
    } else {
      Notch.show(
        'Downloading "${s.title}"',
        icon: Icons.cloud_download_rounded,
      );
    }
  }

  Future<void> _downloadAllCloud() async {
    final n = await context.read<CloudSyncStore>().downloadAllGhosts();
    if (!mounted) return;
    Notch.show(
      n == 0
          ? 'Nothing new to download'
          : 'Downloading $n song${n == 1 ? '' : 's'} from the cloud',
      icon: Icons.cloud_download_rounded,
    );
  }

  Future<void> _removeCloudSong(CloudSong s) async {
    final ok = await confirmDelete(
      context,
      title: 'Remove from the cloud?',
      message:
          'Remove "${s.title}" from the cloud? It will disappear from your other devices too.',
      confirmLabel: 'Remove',
    );
    if (!ok || !mounted) return;
    await context.read<CloudSyncStore>().removeFromCloud(s.videoId);
  }

  void _moveToAll(DownloadedVideo v) {
    context.read<DownloadsStore>().moveToCategory(v.id, null);
    Notch.show(
      'Moved "${v.title}" back to All',
      icon: Icons.playlist_remove_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<DownloadsStore>();
    // Songs saved in the cloud that are not on this phone yet, shown at the
    // bottom of the All playlist.
    final cloud = context.watch<CloudSyncStore>();
    if (_selected != null && store.categoryById(_selected!) == null) {
      _selected = null;
    }
    final videos = store.videosIn(_selected);
    final queue = store.queueItems;
    final ghosts = _selected == null ? cloud.ghosts : const <CloudSong>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Downloads',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Text(
                      '${downloadsLabel(store.videos.length)} · ${formatBytes(store.totalBytes)}',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              if (store.videos.isNotEmpty)
                IconButton(
                  tooltip: 'Delete all downloads',
                  onPressed: () async {
                    final ok = await confirmDelete(
                      context,
                      title: 'Delete all downloads?',
                      message:
                          'All ${store.videos.length} songs will be removed from this phone. This cannot be undone.',
                      confirmLabel: 'Delete all',
                    );
                    if (ok) await store.deleteAllDownloads();
                  },
                  icon: const Icon(Icons.delete_sweep_rounded),
                  color: Colors.white54,
                ),
            ],
          ),
          const SizedBox(height: 10),
          _buildCategoryBar(store),
          const SizedBox(height: 10),
          if (queue.isNotEmpty) ...[
            _QueuePanel(
              items: queue,
              open: _queueOpen,
              onToggle: () => setState(() => _queueOpen = !_queueOpen),
            ),
            const SizedBox(height: 10),
          ],
          Expanded(
            child: (videos.isEmpty && ghosts.isEmpty)
                ? _EmptyState(
                    inCategory: _selected != null,
                    sortedAway: _selected == null && store.videos.isNotEmpty,
                  )
                : Listener(
                    onPointerDown: (e) => _dragPos = e.position,
                    onPointerMove: (e) => _dragPos = e.position,
                    child: ListView.builder(
                      key: _listKey,
                      controller: _listScroll,
                      padding: const EdgeInsets.only(bottom: 170),
                      itemCount:
                          videos.length +
                          (ghosts.isEmpty ? 0 : ghosts.length + 1),
                      itemBuilder: (context, i) {
                        if (i == videos.length) {
                          return _CloudHeader(
                            count: ghosts.length,
                            online: cloud.online,
                            pending: cloud.pendingCount,
                            onDownloadAll: _downloadAllCloud,
                          );
                        }
                        if (i > videos.length) {
                          final g = ghosts[i - videos.length - 1];
                          return _CloudRow(
                            key: ValueKey('cloud_${g.videoId}'),
                            song: g,
                            state: store.stateOf(g.videoId),
                            progress: store.progressOf(g.videoId),
                            onDownload: () => _downloadCloudSong(g),
                            onDelete: () => _removeCloudSong(g),
                          );
                        }
                        final v = videos[i];
                        return _SongRow(
                          key: ValueKey(v.id),
                          video: v,
                          dragging: _draggingVideo,
                          onPlay: () => context
                              .read<PlayerHub>()
                              .playDownloaded(videos, i),
                          onRename: () => _renameSong(v),
                          onDelete: () => _deleteSong(v),
                          onSearch: () =>
                              context.read<NavController>().searchFor(v.title),
                          onMoveToAll: _selected == null
                              ? null
                              : () => _moveToAll(v),
                          onReorder: (dragged) => context
                              .read<DownloadsStore>()
                              .reorderVideo(dragged.id, v.id),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryBar(DownloadsStore store) {
    final accent = Theme.of(context).colorScheme.primary;
    return ValueListenableBuilder<bool>(
      valueListenable: _draggingVideo,
      builder: (context, dragging, _) => GlassContainer(
        borderRadius: 18,
        opacity: 0.12,
        padding: const EdgeInsets.fromLTRB(8, 0, 0, 0),
        borderColor: dragging ? accent.withValues(alpha: 0.6) : null,
        child: SizedBox(
          height: _FolderTile.height + 16,
          child: Row(
            children: [
              _AllChip(
                selected: _selected == null,
                count: store.countIn(null),
                onTap: () => setState(() => _selected = null),
                onShuffle: () => context
                    .read<PlayerHub>()
                    .playDownloadedShuffled(store.videosIn(null)),
              ),
              const SizedBox(width: 8),
              Container(
                width: 1,
                height: 44,
                color: accent.withValues(alpha: 0.25),
              ),
              Expanded(
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) {
                    final f = rect.width > _fade * 2 ? _fade / rect.width : 0.0;
                    return LinearGradient(
                      colors: const [
                        Colors.transparent,
                        Colors.white,
                        Colors.white,
                        Colors.transparent,
                      ],
                      stops: [0, f, 1 - f, 1],
                    ).createShader(rect);
                  },
                  child: ListView(
                    controller: _barScroll,
                    scrollDirection: Axis.horizontal,
                    clipBehavior: Clip.hardEdge,
                    padding: const EdgeInsets.symmetric(
                      horizontal: _fade,
                      vertical: 8,
                    ),
                    children: [
                      for (final c in store.categories)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _CategoryChip(
                            key: ValueKey(c.id),
                            category: c,
                            count: store.countIn(c.id),
                            selected: _selected == c.id,
                            onTap: () => setState(() => _selected = c.id),
                            onShuffle: () => context
                                .read<PlayerHub>()
                                .playDownloadedShuffled(store.videosIn(c.id)),
                            onMenu: () => _categoryMenu(c),
                          ),
                        ),
                      _NewCategoryButton(onTap: _createCategory),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueuePanel extends StatelessWidget {
  final List<DownloadQueueItem> items;
  final bool open;
  final VoidCallback onToggle;

  const _QueuePanel({
    required this.items,
    required this.open,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final store = context.read<DownloadsStore>();
    return GlassContainer(
      borderRadius: 16,
      padding: const EdgeInsets.fromLTRB(12, 4, 6, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.downloading_rounded, color: accent, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Downloading ${items.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(
                    open
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),
          if (open)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 230),
              child: ReorderableListView.builder(
                shrinkWrap: true,
                buildDefaultDragHandles: false,
                itemCount: items.length,
                onReorder: store.reorderQueue,
                itemBuilder: (context, i) => _QueueRow(
                  key: ValueKey(items[i].video.id),
                  item: items[i],
                  index: i,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final DownloadQueueItem item;
  final int index;

  const _QueueRow({super.key, required this.item, required this.index});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final store = context.read<DownloadsStore>();
    final failed = item.state == DownloadState.failed;
    final running = item.state == DownloadState.downloading;
    final progress = item.progress;

    Widget status;
    if (failed) {
      status = _RetryCountdown(retryAt: item.retryAt, error: item.error);
    } else if (running) {
      status = Text(
        progress == null ? 'Starting...' : '${(progress * 100).round()}%',
        style: const TextStyle(color: Colors.white60, fontSize: 11.5),
      );
    } else {
      status = const Text(
        'Waiting in line',
        style: TextStyle(color: Colors.white38, fontSize: 11.5),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(
                Icons.drag_indicator_rounded,
                color: Colors.white30,
                size: 20,
              ),
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 56,
              height: 32,
              child: ThumbImage(source: item.video.thumbnailUrl),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                if (running || (progress != null && progress > 0))
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 3,
                      color: failed ? Colors.redAccent.shade200 : accent,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                const SizedBox(height: 3),
                status,
              ],
            ),
          ),
          if (failed)
            IconButton(
              onPressed: () => store.retryDownload(item.video.id),
              icon: const Icon(Icons.refresh_rounded, size: 20),
              color: Colors.white70,
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            onPressed: () => store.cancelDownload(item.video.id),
            icon: const Icon(Icons.close_rounded, size: 20),
            color: Colors.white54,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _RetryCountdown extends StatefulWidget {
  final DateTime? retryAt;
  final String? error;
  const _RetryCountdown({required this.retryAt, required this.error});

  @override
  State<_RetryCountdown> createState() => _RetryCountdownState();
}

class _RetryCountdownState extends State<_RetryCountdown> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.retryAt;
    final secs = at == null
        ? 0
        : at.difference(DateTime.now()).inSeconds.clamp(0, 999);
    final err = widget.error;
    return Text(
      '${err == null || err.isEmpty ? 'Failed' : err} · retrying in ${secs}s',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: Colors.redAccent.shade200, fontSize: 11.5),
    );
  }
}

class _SongRow extends StatelessWidget {
  final DownloadedVideo video;
  final ValueNotifier<bool> dragging;
  final VoidCallback onPlay;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onSearch;
  final VoidCallback? onMoveToAll;
  final void Function(DownloadedVideo dragged) onReorder;

  const _SongRow({
    super.key,
    required this.video,
    required this.dragging,
    required this.onPlay,
    required this.onRename,
    required this.onDelete,
    required this.onSearch,
    required this.onReorder,
    this.onMoveToAll,
  });

  Future<void> _openMenu(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _Sheet(
        title: video.title,
        children: [
          if (onMoveToAll != null)
            _SheetTile(
              Icons.playlist_remove_rounded,
              'Move back to All',
              () => Navigator.pop(ctx, 'all'),
            ),
          _SheetTile(
            Icons.search_rounded,
            'Search on YouTube',
            () => Navigator.pop(ctx, 'search'),
          ),
          _SheetTile(
            Icons.edit_rounded,
            'Rename',
            () => Navigator.pop(ctx, 'rename'),
          ),
          _SheetTile(
            Icons.delete_outline_rounded,
            'Delete',
            () => Navigator.pop(ctx, 'delete'),
            danger: true,
          ),
        ],
      ),
    );
    switch (action) {
      case 'all':
        onMoveToAll?.call();
      case 'search':
        onSearch();
      case 'rename':
        onRename();
      case 'delete':
        onDelete();
    }
  }

  Widget _card(
    BuildContext context, {
    required bool playing,
    bool drop = false,
    bool lifted = false,
  }) {
    final accent = Theme.of(context).colorScheme.primary;
    final v = video;
    final meta = [
      if (v.author.isNotEmpty) v.author,
      formatDuration(v.duration),
      formatBytes(v.sizeBytes),
      if (v.audioOnly) 'Audio',
    ].join('  •  ');

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: lifted ? AppColors.panel : Colors.white.withValues(alpha: 0.04),
        border: Border.all(
          color: drop || lifted
              ? accent
              : playing
              ? accent.withValues(alpha: 0.6)
              : Colors.white.withValues(alpha: 0.06),
          width: drop ? 2 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
        child: Row(
          children: [
            _Thumb(video: v, width: 100),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    v.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: playing ? accent : Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
            if (!lifted)
              IconButton(
                onPressed: () => _openMenu(context),
                icon: const Icon(Icons.more_vert_rounded, size: 20),
                color: Colors.white60,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 40),
              )
            else
              const SizedBox(width: 12),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final playing = context.select<PlayerHub, bool>(
      (h) => h.current?.videoId == video.videoId,
    );
    final accent = Theme.of(context).colorScheme.primary;

    // Dropping a song on another song of the same playlist puts it there.
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: DragTarget<DownloadedVideo>(
        onWillAcceptWithDetails: (d) =>
            d.data.id != video.id && d.data.categoryId == video.categoryId,
        onAcceptWithDetails: (d) => onReorder(d.data),
        builder: (context, candidates, _) {
          final draggable = LongPressDraggable<DownloadedVideo>(
            data: video,
            delay: const Duration(milliseconds: 350),
            hapticFeedbackOnStart: true,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            onDragStarted: () => dragging.value = true,
            onDragEnd: (_) => dragging.value = false,
            onDraggableCanceled: (_, _) => dragging.value = false,
            feedback: Transform.translate(
              offset: const Offset(-48, -34),
              child: Material(
                color: Colors.transparent,
                elevation: 10,
                shadowColor: accent,
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 270,
                  child: _card(context, playing: false, lifted: true),
                ),
              ),
            ),
            childWhenDragging: Opacity(
              opacity: 0.3,
              child: _card(context, playing: playing),
            ),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onPlay,
              child: _card(
                context,
                playing: playing,
                drop: candidates.isNotEmpty,
              ),
            ),
          );
          return Dismissible(
            key: ValueKey('swipe-${video.id}'),
            direction: DismissDirection.horizontal,
            background: _swipeBg(
              accent.withValues(alpha: 0.25),
              Icons.edit_rounded,
              accent,
              Alignment.centerLeft,
            ),
            secondaryBackground: _swipeBg(
              Colors.redAccent.shade200.withValues(alpha: 0.25),
              Icons.delete_outline_rounded,
              Colors.redAccent.shade200,
              Alignment.centerRight,
            ),
            confirmDismiss: (dir) async {
              if (dir == DismissDirection.startToEnd) {
                onRename();
              } else {
                onDelete();
              }
              return false;
            },
            child: draggable,
          );
        },
      ),
    );
  }

  Widget _swipeBg(Color bg, IconData icon, Color fg, Alignment align) {
    return Container(
      alignment: align,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: fg),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool inCategory;
  final bool sortedAway;
  const _EmptyState({required this.inCategory, required this.sortedAway});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final title = inCategory
        ? 'This playlist is empty'
        : sortedAway
        ? 'Everything is sorted'
        : 'No downloads yet';
    final body = inCategory
        ? 'Go to All, hold a song, and drag it onto this playlist.'
        : sortedAway
        ? 'All your songs are inside playlists. Tap a playlist above.'
        : 'Tap the download button next to a song in Search. Songs are saved inside the app and play offline.';
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
              child: Icon(Icons.download_done_rounded, color: accent, size: 32),
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
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Sheet({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: GlassContainer(
          borderRadius: 22,
          opacity: 0.12,
          padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(child: Column(children: children)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  const _SheetTile(this.icon, this.label, this.onTap, {this.danger = false});

  @override
  Widget build(BuildContext context) {
    final color = danger ? Colors.redAccent.shade200 : Colors.white;
    return ListTile(
      onTap: onTap,
      leading: Icon(icon, color: color, size: 22),
      title: Text(label, style: TextStyle(color: color, fontSize: 14.5)),
      dense: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

Future<String?> _promptName(
  BuildContext context, {
  required String title,
  required String hint,
  required String confirmLabel,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(
      title: title,
      hint: hint,
      confirmLabel: confirmLabel,
      initial: initial,
    ),
  );
}

class _NameDialog extends StatefulWidget {
  final String title;
  final String hint;
  final String confirmLabel;
  final String initial;
  const _NameDialog({
    required this.title,
    required this.hint,
    required this.confirmLabel,
    required this.initial,
  });

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _done() {
    final t = _c.text.trim();
    if (t.isEmpty) return;
    Navigator.pop(context, t);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: GlassContainer(
        borderRadius: 20,
        opacity: 0.12,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _c,
              autofocus: true,
              maxLength: 80,
              onSubmitted: (_) => _done(),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: widget.hint,
                hintStyle: const TextStyle(color: Colors.white38),
                counterText: '',
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.06),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _done,
                  child: Text(widget.confirmLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

enum _CategoryDeleteChoice { categoryOnly, withVideos }

class _DeleteCategoryDialog extends StatelessWidget {
  final String name;
  final int count;
  const _DeleteCategoryDialog({required this.name, required this.count});

  @override
  Widget build(BuildContext context) {
    final danger = Colors.redAccent.shade200;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: GlassContainer(
        borderRadius: 20,
        opacity: 0.12,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Delete "$name"?',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'It has ${downloadsLabel(count).toLowerCase()}. What should happen to them?',
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _CategoryDeleteChoice.categoryOnly),
              child: const Text('Keep the songs, delete the playlist'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, _CategoryDeleteChoice.withVideos),
              style: FilledButton.styleFrom(backgroundColor: danger),
              child: const Text('Delete playlist and songs'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final DownloadedVideo video;
  final double width;

  const _Thumb({required this.video, required this.width});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: width,
        height: width * 9 / 16,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ThumbImage(source: video.thumbSource),
            Positioned(
              right: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  formatDuration(video.duration),
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RowIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  const _RowIcon({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      color: color ?? Colors.white60,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 36),
    );
  }
}

/// A playlist tile: icon, name (always two lines tall so every tile matches)
/// and the number of songs inside.
class _FolderTile extends StatelessWidget {
  static const double width = 78;
  static const double height = 72;

  final String label;
  final int count;
  final bool selected;
  final bool hovering;
  final bool ghost;
  final IconData icon;
  final IconData selectedIcon;
  final Widget? corner;

  /// When set (and the tile is selected) the icon turns into a button.
  final VoidCallback? onIconTap;

  const _FolderTile({
    required this.label,
    required this.count,
    required this.selected,
    this.hovering = false,
    this.ghost = false,
    this.icon = Icons.queue_music_rounded,
    this.selectedIcon = Icons.queue_music_rounded,
    this.corner,
    this.onIconTap,
  });

  Widget _iconWidget(Color accent, bool active) {
    final iconWidget = AnimatedScale(
      duration: const Duration(milliseconds: 180),
      scale: hovering ? 1.15 : 1,
      child: Icon(
        selected ? selectedIcon : icon,
        size: 20,
        color: active ? accent : accent.withValues(alpha: 0.75),
      ),
    );
    final tap = onIconTap;
    if (!selected || ghost || tap == null) return iconWidget;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: tap,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: accent.withValues(alpha: hovering ? 0.30 : 0.18),
        ),
        child: iconWidget,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final active = selected || hovering || ghost;

    final List<Color> colors;
    final Color borderColor;
    if (hovering) {
      colors = [accent.withValues(alpha: 0.42), accent.withValues(alpha: 0.18)];
      borderColor = accent.withValues(alpha: 0.95);
    } else if (active) {
      colors = [accent.withValues(alpha: 0.30), accent.withValues(alpha: 0.10)];
      borderColor = accent.withValues(alpha: 0.6);
    } else {
      colors = [accent.withValues(alpha: 0.12), accent.withValues(alpha: 0.04)];
      borderColor = accent.withValues(alpha: 0.22);
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: ghost ? const Color(0xFF231417) : null,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        border: Border.all(color: borderColor, width: hovering ? 2 : 1.2),
        boxShadow: active
            ? [
                BoxShadow(
                  color: accent.withValues(
                    alpha: ghost || hovering ? 0.45 : 0.22,
                  ),
                  blurRadius: ghost || hovering ? 22 : 12,
                ),
              ]
            : null,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _iconWidget(accent, active),
                    const SizedBox(height: 2),
                    SizedBox(
                      height: 26,
                      child: Center(
                        child: Text(
                          label,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: active ? Colors.white : Colors.white70,
                            fontWeight: FontWeight.w700,
                            fontSize: 11,
                            height: 1.15,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      downloadsLabel(count),
                      maxLines: 1,
                      style: TextStyle(
                        color: active ? Colors.white70 : Colors.white38,
                        fontSize: 9.5,
                        height: 1.1,
                        fontWeight: FontWeight.w500,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (corner != null) Positioned(top: 3, right: 3, child: corner!),
        ],
      ),
    );
  }
}

class _AllChip extends StatelessWidget {
  final bool selected;
  final int count;
  final VoidCallback onTap;
  final VoidCallback onShuffle;

  const _AllChip({
    required this.selected,
    required this.count,
    required this.onTap,
    required this.onShuffle,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.read<DownloadsStore>();
    // Dropping a song here takes it out of its playlist and puts it back in All.
    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) {
        final data = d.data;
        return data is DownloadedVideo && data.categoryId != null;
      },
      onAcceptWithDetails: (d) {
        final data = d.data;
        if (data is DownloadedVideo) {
          store.moveToCategory(data.id, null);
          Notch.show(
            'Moved "${data.title}" back to All',
            icon: Icons.video_library_rounded,
          );
        }
      },
      builder: (context, candidates, _) => GestureDetector(
        onTap: onTap,
        child: _FolderTile(
          label: 'All',
          count: count,
          selected: selected,
          hovering: candidates.isNotEmpty,
          icon: Icons.video_library_outlined,
          selectedIcon: Icons.play_arrow_rounded,
          onIconTap: count > 0 ? onShuffle : null,
        ),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final VideoCategory category;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onShuffle;
  final VoidCallback onMenu;

  const _CategoryChip({
    super.key,
    required this.category,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onShuffle,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final store = context.read<DownloadsStore>();
    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) {
        final data = d.data;
        if (data is DownloadedVideo) return data.categoryId != category.id;
        if (data is VideoCategory) return data.id != category.id;
        return false;
      },
      onAcceptWithDetails: (d) {
        final data = d.data;
        if (data is DownloadedVideo) {
          store.moveToCategory(data.id, category.id);
          Notch.show(
            'Moved "${data.title}" to ${category.name}',
            icon: Icons.playlist_add_check_rounded,
          );
        } else if (data is VideoCategory) {
          store.reorderCategory(data.id, category.id);
        }
      },
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        final tile = _FolderTile(
          label: category.name,
          count: count,
          selected: selected,
          hovering: hovering,
          selectedIcon: Icons.play_arrow_rounded,
          onIconTap: count > 0 ? onShuffle : null,
          corner: selected
              ? GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onMenu,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.3),
                    ),
                    child: const Icon(
                      Icons.more_horiz_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                )
              : null,
        );
        // Hold a playlist tile and drag it onto another one to reorder.
        return LongPressDraggable<VideoCategory>(
          data: category,
          delay: const Duration(milliseconds: 250),
          hapticFeedbackOnStart: true,
          feedback: Material(
            type: MaterialType.transparency,
            child: Opacity(
              opacity: 0.85,
              child: Transform.rotate(
                angle: -0.04,
                child: Transform.scale(
                  scale: 1.06,
                  child: _FolderTile(
                    label: category.name,
                    count: count,
                    selected: true,
                    ghost: true,
                  ),
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: tile),
          child: GestureDetector(onTap: onTap, child: tile),
        );
      },
    );
  }
}

class _NewCategoryButton extends StatelessWidget {
  final VoidCallback onTap;
  const _NewCategoryButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: _FolderTile.width,
        height: _FolderTile.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: accent.withValues(alpha: 0.04),
          border: Border.all(color: accent.withValues(alpha: 0.35), width: 1.2),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.playlist_add_rounded, size: 20, color: accent),
              const SizedBox(height: 3),
              Text(
                'New\nplaylist',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: accent,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _DeleteChoice { cancel, deviceAndCloud, deviceOnly }

/// Delete dialog for a song that is also saved in the cloud.
Future<_DeleteChoice> _askDeleteChoice(
  BuildContext context,
  DownloadedVideo v,
) async {
  final danger = Colors.redAccent.shade200;
  final result = await showDialog<_DeleteChoice>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: GlassContainer(
          borderRadius: 20,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: danger.withValues(alpha: 0.15),
                    ),
                    child: Icon(
                      Icons.warning_amber_rounded,
                      color: danger,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Delete download?',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '"${v.title}" is also saved in your cloud. Delete it only from this device, or from the cloud too?',
                style: const TextStyle(
                  color: Colors.white70,
                  height: 1.4,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 18),
              // Stacked on a phone: three buttons do not fit in one row.
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger,
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: () =>
                    Navigator.pop(ctx, _DeleteChoice.deviceAndCloud),
                child: const Text('Delete from Device & Cloud'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger.withValues(alpha: 0.55),
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed: () => Navigator.pop(ctx, _DeleteChoice.deviceOnly),
                child: const Text('Delete from Device'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white70,
                  minimumSize: const Size.fromHeight(44),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                ),
                onPressed: () => Navigator.pop(ctx, _DeleteChoice.cancel),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result ?? _DeleteChoice.cancel;
}

/// Heading of the "Cloud Saves" section at the bottom of All.
class _CloudHeader extends StatelessWidget {
  final int count;
  final bool online;
  final int pending;
  final VoidCallback onDownloadAll;
  const _CloudHeader({
    required this.count,
    required this.online,
    required this.pending,
    required this.onDownloadAll,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final status = !online
        ? 'Offline${pending > 0 ? '  •  $pending waiting' : ''}'
        : pending > 0
        ? 'Syncing $pending...'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 0, 10),
      child: Row(
        children: [
          Icon(Icons.cloud_outlined, size: 17, color: accent),
          const SizedBox(width: 8),
          const Text(
            'Cloud Saves',
            style: TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: accent.withValues(alpha: 0.15),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                color: accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: 'Download all cloud saves to this phone',
            onPressed: onDownloadAll,
            icon: Icon(Icons.cloud_download_rounded, size: 19, color: accent),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 34, minHeight: 36),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: status == null
                  ? const SizedBox.shrink()
                  : Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11.5,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A song that is in the cloud but not on this phone: a faded card with a
/// cloud download button.
class _CloudRow extends StatelessWidget {
  final CloudSong song;
  final DownloadState state;
  final double? progress;
  final VoidCallback onDownload;
  final VoidCallback onDelete;

  const _CloudRow({
    super.key,
    required this.song,
    required this.state,
    required this.progress,
    required this.onDownload,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final busy =
        state == DownloadState.queued ||
        state == DownloadState.downloading ||
        state == DownloadState.failed;
    final meta = [
      if (song.author.isNotEmpty) song.author,
      formatDuration(song.duration),
      if (song.audioOnly) 'Audio',
      'In the cloud',
    ].join('  •  ');

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(6, 6, 0, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: Colors.white.withValues(alpha: 0.02),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: 0.5,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 100,
                height: 100 * 9 / 16,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ThumbImage(source: song.thumbnailUrl),
                    Container(
                      color: Colors.black45,
                      child: const Center(
                        child: Icon(
                          Icons.cloud_download_outlined,
                          color: Colors.white,
                          size: 24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Opacity(
              opacity: 0.65,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13.5,
                      height: 1.25,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Colors.white54,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: state == DownloadState.downloading ? progress : null,
                ),
              ),
            )
          else
            _RowIcon(
              icon: Icons.cloud_download_rounded,
              tooltip: 'Download to this phone',
              color: accent,
              onTap: onDownload,
            ),
          _RowIcon(
            icon: Icons.delete_outline_rounded,
            tooltip: 'Remove from the cloud',
            color: Colors.redAccent.shade100,
            onTap: onDelete,
          ),
        ],
      ),
    );
  }
}
