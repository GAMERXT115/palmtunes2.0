import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart' show Icons;

import 'auth_store.dart';
import 'downloads.dart';
import 'search.dart';
import 'ui.dart' show Notch;

/// A song kept in the cloud: only the links and details needed to download it
/// again (video ID, thumbnail address, title...), never the file itself.
class CloudSong {
  final String videoId;
  final String title;
  final String author;
  final int? durationMs;
  final String thumbnailUrl;
  final bool audioOnly;
  final DateTime savedAt;

  const CloudSong({
    required this.videoId,
    required this.title,
    required this.author,
    required this.durationMs,
    required this.thumbnailUrl,
    required this.audioOnly,
    required this.savedAt,
  });

  Duration? get duration =>
      durationMs == null ? null : Duration(milliseconds: durationMs!);

  factory CloudSong.fromDownload(DownloadedVideo v) => CloudSong(
    videoId: v.videoId,
    title: v.title,
    author: v.author,
    durationMs: v.duration?.inMilliseconds,
    thumbnailUrl: v.thumbnailUrl.isNotEmpty
        ? v.thumbnailUrl
        : 'https://i.ytimg.com/vi/${v.videoId}/hqdefault.jpg',
    audioOnly: v.audioOnly,
    savedAt: DateTime.now(),
  );

  YtVideo toYtVideo() => YtVideo(
    id: videoId,
    title: title,
    author: author,
    duration: duration,
    thumbnailUrl: thumbnailUrl,
  );

  /// The document in users/{uid}/cloudSongs/{videoId}.
  Map<String, dynamic> toFirestore() => {
    'videoId': videoId,
    'title': title,
    'author': author,
    'durationMs': durationMs,
    'thumbnailUrl': thumbnailUrl,
    'thumbnailId': videoId,
    'audioOnly': audioOnly,
    'savedAt': Timestamp.fromDate(savedAt),
    'device': Platform.localHostname,
  };

  factory CloudSong.fromFirestore(String id, Map<String, dynamic> m) {
    final saved = m['savedAt'];
    return CloudSong(
      videoId: (m['videoId'] as String?) ?? id,
      title: (m['title'] as String?) ?? 'Untitled',
      author: (m['author'] as String?) ?? '',
      durationMs: (m['durationMs'] as num?)?.toInt(),
      thumbnailUrl:
          (m['thumbnailUrl'] as String?) ??
          'https://i.ytimg.com/vi/$id/hqdefault.jpg',
      audioOnly: (m['audioOnly'] as bool?) ?? false,
      savedAt: saved is Timestamp ? saved.toDate() : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
    'videoId': videoId,
    'title': title,
    'author': author,
    'durationMs': durationMs,
    'thumbnailUrl': thumbnailUrl,
    'audioOnly': audioOnly,
    'savedAt': savedAt.toIso8601String(),
  };

  factory CloudSong.fromJson(Map<String, dynamic> m) => CloudSong(
    videoId: m['videoId'] as String,
    title: (m['title'] as String?) ?? 'Untitled',
    author: (m['author'] as String?) ?? '',
    durationMs: (m['durationMs'] as num?)?.toInt(),
    thumbnailUrl: (m['thumbnailUrl'] as String?) ?? '',
    audioOnly: (m['audioOnly'] as bool?) ?? false,
    savedAt:
        DateTime.tryParse((m['savedAt'] as String?) ?? '') ?? DateTime.now(),
  );
}

/// One thing waiting to be sent to the cloud.
class _Op {
  final bool remove;
  final CloudSong? song;
  final DateTime at;
  _Op.add(CloudSong this.song) : remove = false, at = DateTime.now();
  _Op.remove() : remove = true, song = null, at = DateTime.now();
  _Op._(this.remove, this.song, this.at);

  Map<String, dynamic> toJson() => {
    'remove': remove,
    'song': song?.toJson(),
    'at': at.toIso8601String(),
  };

  factory _Op.fromJson(Map<String, dynamic> m) => _Op._(
    m['remove'] == true,
    m['song'] == null
        ? null
        : CloudSong.fromJson(Map<String, dynamic>.from(m['song'] as Map)),
    DateTime.tryParse((m['at'] as String?) ?? '') ?? DateTime.now(),
  );
}

/// Keeps the songs a person downloaded in sync with their cloud saves.
///
/// Offline first: every change is first written to a queue on this phone,
/// and the queue is sent to Firestore silently whenever there is internet.
/// Nothing here blocks or complains when offline; the Cloud Saves list is
/// kept in a local copy too, so it still shows without internet.
class CloudSyncStore extends ChangeNotifier {
  static const _probeHost = 'firestore.googleapis.com';

  final AuthStore auth;
  final DownloadsStore downloads;
  CloudSyncStore(this.auth, this.downloads);

  SharedPreferences? _prefs;
  String? _uid;
  final Map<String, CloudSong> _cloud = {};
  final Map<String, _Op> _queue = {};

  /// Songs that were in the cloud at some point. A song that is on this
  /// computer, in this set, but no longer in the cloud was removed from the
  /// cloud on another device, so it must not be uploaded again.
  final Set<String> _synced = {};

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  Timer? _timer;
  bool _online = true;
  bool _flushing = false;
  bool _wasEnabled = false;
  bool _wasAuto = false;
  bool _fresh = false; // a snapshot from the server has arrived
  bool _autoDone = false; // auto-download already ran for this launch
  DateTime? _lastSynced;
  int _upTotal = 0;
  int _upDone = 0;
  String _localSig = '';
  bool _disposed = false;

  bool get online => _online;

  /// When the cloud and this phone last matched.
  DateTime? get lastSynced => _lastSynced;
  int get pendingCount => _queue.length;
  bool get enabled => _uid != null && auth.cloudSaving;

  /// Cloud songs that are not on this phone, newest first. These are the
  /// "ghost cards" at the bottom of the All playlist.
  List<CloudSong> get ghosts {
    if (_uid == null) return const [];
    final local = {for (final v in downloads.videos) v.videoId};
    final list =
        _cloud.values
            .where((s) => !local.contains(s.videoId))
            .where((s) => _queue[s.videoId]?.remove != true)
            .toList()
          ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return list;
  }

  bool inCloud(String videoId) =>
      _uid != null &&
      (_cloud.containsKey(videoId) || (_queue[videoId]?.remove == false));

  /// Whether deleting a download can also offer to delete it from the cloud.
  bool canOfferCloudDelete(String videoId) =>
      auth.isSignedIn && inCloud(videoId);

  Future<void> attach() async {
    _prefs = await SharedPreferences.getInstance();
    auth.addListener(_onAuth);
    downloads.addListener(_onDownloads);
    _onAuth();
  }

  // ---------------------------------------------------------------------
  // Account changes
  // ---------------------------------------------------------------------

  void _onAuth() {
    final uid = auth.status == AuthStatus.signedIn ? auth.uid : null;
    if (uid != _uid) {
      _unbind();
      if (uid != null) _bind(uid);
    }
    final nowEnabled = enabled;
    if (nowEnabled && !_wasEnabled) {
      _reconcile();
      unawaited(flush());
    }
    _wasEnabled = nowEnabled;
    final auto = _uid != null && auth.autoDownloadCloud;
    if (auto && !_wasAuto) _autoDone = false;
    _wasAuto = auto;
    _maybeAutoDownload();
    notifyListeners();
  }

  void _bind(String uid) {
    _uid = uid;
    _cloud.clear();
    _queue.clear();
    _synced.clear();
    final p = _prefs;
    if (p != null) {
      try {
        for (final e
            in (jsonDecode(p.getString('pt_cc_$uid') ?? '[]') as List)) {
          final s = CloudSong.fromJson(Map<String, dynamic>.from(e as Map));
          _cloud[s.videoId] = s;
        }
        for (final e
            in (jsonDecode(p.getString('pt_cq_$uid') ?? '[]') as List)) {
          final m = Map<String, dynamic>.from(e as Map);
          _queue[m['id'] as String] = _Op.fromJson(
            Map<String, dynamic>.from(m['op'] as Map),
          );
        }
        _synced.addAll(p.getStringList('pt_cs_$uid') ?? const []);
        _lastSynced = DateTime.tryParse(p.getString('pt_cl_$uid') ?? '');
      } catch (e) {
        debugPrint('[PalmTunes] Cloud cache read failed -> $e');
      }
    }
    _subscribe();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
    unawaited(_tick());
  }

  void _unbind() {
    _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _uid = null;
    _cloud.clear();
    _queue.clear();
    _synced.clear();
    _localSig = '';
    _fresh = false;
    _autoDone = false;
    _lastSynced = null;
    _upTotal = 0;
    _upDone = 0;
  }

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('cloudSongs');

  void _subscribe() {
    final uid = _uid;
    if (uid == null) return;
    _sub?.cancel();
    _sub = _col(uid)
        .snapshots(includeMetadataChanges: true)
        .listen(
          _onSnapshot,
          onError: (Object e) {
            debugPrint('[PalmTunes] Cloud listener stopped -> $e');
            _sub = null;
          },
        );
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    final next = <String, CloudSong>{};
    for (final d in snap.docs) {
      try {
        next[d.id] = CloudSong.fromFirestore(d.id, d.data());
      } catch (_) {}
    }
    _cloud
      ..clear()
      ..addAll(next);
    _synced.addAll(next.keys);
    _persistCloud();
    _persistSynced();
    _reconcile();
    if (!snap.metadata.isFromCache) {
      _fresh = true;
      if (_queue.isEmpty) _markSynced();
      _maybeAutoDownload();
    }
    notifyListeners();
  }

  void _markSynced() {
    final uid = _uid;
    if (uid == null) return;
    _lastSynced = DateTime.now();
    _prefs?.setString('pt_cl_$uid', _lastSynced!.toIso8601String());
  }

  /// "Auto-Download Songs from Cloud": once per launch, after the cloud list
  /// is fresh, downloads every cloud song that is not on this phone.
  void _maybeAutoDownload() {
    if (_uid == null || !_fresh || _autoDone || !auth.autoDownloadCloud) return;
    _autoDone = true;
    unawaited(() async {
      final n = await downloadAllGhosts();
      if (n > 0) {
        Notch.show(
          'Downloading $n song${n == 1 ? '' : 's'} from the cloud',
          icon: Icons.cloud_download_rounded,
        );
      }
    }());
  }

  // ---------------------------------------------------------------------
  // What to send
  // ---------------------------------------------------------------------

  void _onDownloads() {
    final sig = downloads.videos.map((v) => v.videoId).join(',');
    if (sig == _localSig) return;
    _localSig = sig;
    _reconcile();
    notifyListeners();
  }

  /// Puts every song on this phone that is not in the cloud yet into the
  /// queue (when cloud saving is on).
  void _reconcile() {
    if (!enabled) return;
    final localIds = {for (final v in downloads.videos) v.videoId};
    _synced.removeWhere(
      (id) => !localIds.contains(id) && !_cloud.containsKey(id),
    );
    var changed = false;
    for (final v in downloads.videos) {
      final id = v.videoId;
      if (_cloud.containsKey(id)) continue;
      final op = _queue[id];
      if (op != null) {
        if (!op.remove) continue;
        // A removal is waiting, but this song was downloaded again after it.
        if (!v.addedAt.isAfter(op.at)) continue;
      } else if (_synced.contains(id)) {
        // It was in the cloud before and is gone: removed on another device.
        continue;
      }
      _queue[id] = _Op.add(CloudSong.fromDownload(v));
      _synced.remove(id);
      changed = true;
    }
    if (changed) {
      _persistQueue();
      unawaited(flush());
    }
  }

  /// Removes a song from the cloud (it stays on this phone if it is here).
  Future<void> removeFromCloud(String videoId) async {
    if (_uid == null) return;
    _queue[videoId] = _Op.remove();
    _cloud.remove(videoId);
    _synced.remove(videoId);
    _persistQueue();
    _persistCloud();
    _persistSynced();
    notifyListeners();
    unawaited(flush());
  }

  /// Starts the download of every cloud song that is not on this phone.
  /// Returns how many were started.
  Future<int> downloadAllGhosts() async {
    var started = 0;
    for (final s in ghosts) {
      final st = downloads.stateOf(s.videoId);
      if (st == DownloadState.queued || st == DownloadState.downloading) {
        continue;
      }
      final msg = await downloads.startDownload(s.toYtVideo());
      if (msg == null) started++;
    }
    return started;
  }

  /// Downloads a cloud song to this phone.
  Future<String?> downloadGhost(CloudSong song) =>
      downloads.startDownload(song.toYtVideo());

  // ---------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------

  Future<bool> _probe() async {
    var ok = false;
    try {
      final r = await InternetAddress.lookup(_probeHost)
          .timeout(const Duration(seconds: 4));
      ok = r.isNotEmpty && r.first.rawAddress.isNotEmpty;
    } catch (_) {}
    if (ok != _online) {
      _online = ok;
      notifyListeners();
    }
    return ok;
  }

  Future<void> _tick() async {
    if (_disposed || _uid == null) return;
    final online = await _probe();
    if (!online) return;
    if (_sub == null) _subscribe();
    await flush();
  }

  /// Sends whatever is waiting. Silent: if there is no internet it just
  /// returns and the next attempt happens by itself.
  Future<void> flush() async {
    if (_flushing || _uid == null || _queue.isEmpty) return;
    _flushing = true;
    var failed = false;
    var uploading = false;
    try {
      if (!await _probe()) return;
      final uid = _uid;
      if (uid == null) return;
      // The notch shows the uploads as "Uploading 3/20..." until they are done.
      _upTotal = enabled ? _queue.values.where((o) => !o.remove).length : 0;
      _upDone = 0;
      for (final id in _queue.keys.toList()) {
        final op = _queue[id];
        if (op == null) continue;
        if (!op.remove && !enabled) continue;
        try {
          final doc = _col(uid).doc(id);
          if (op.remove) {
            await doc.delete().timeout(const Duration(seconds: 15));
            _synced.remove(id);
          } else {
            uploading = true;
            Notch.show(
              'Uploading ${_upDone + 1}/$_upTotal...',
              icon: Icons.cloud_upload_rounded,
              duration: const Duration(hours: 1),
            );
            await doc
                .set(op.song!.toFirestore(), SetOptions(merge: true))
                .timeout(const Duration(seconds: 15));
            _synced.add(id);
            _cloud.putIfAbsent(id, () => op.song!);
            _upDone++;
          }
          if (identical(_queue[id], op)) _queue.remove(id);
          _persistQueue();
          _persistSynced();
        } catch (e) {
          debugPrint('[PalmTunes] Cloud send failed, will retry -> $e');
          failed = true;
          break;
        }
      }
    } finally {
      _flushing = false;
      if (uploading) Notch.instance.hide();
      _upTotal = 0;
      _upDone = 0;
      if (!failed && _queue.isEmpty && _uid != null) _markSynced();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Local copies
  // ---------------------------------------------------------------------

  void _persistQueue() {
    final uid = _uid;
    if (uid == null) return;
    _prefs?.setString(
      'pt_cq_$uid',
      jsonEncode([
        for (final e in _queue.entries) {'id': e.key, 'op': e.value.toJson()},
      ]),
    );
  }

  void _persistCloud() {
    final uid = _uid;
    if (uid == null) return;
    _prefs?.setString(
      'pt_cc_$uid',
      jsonEncode([for (final s in _cloud.values) s.toJson()]),
    );
  }

  void _persistSynced() {
    final uid = _uid;
    if (uid == null) return;
    _prefs?.setStringList('pt_cs_$uid', _synced.toList());
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _timer?.cancel();
    auth.removeListener(_onAuth);
    downloads.removeListener(_onDownloads);
    super.dispose();
  }
}
