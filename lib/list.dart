import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'auth_store.dart';
import 'bass_meter.dart';
import 'player_hub.dart';
import 'search.dart';
import 'ui.dart';

/// Milliseconds only, so a time survives the trip through the cloud unchanged.
DateTime _nowMs() =>
    DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch);

DateTime _timeOf(Object? v, DateTime fallback) {
  if (v is num) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
  if (v is Timestamp) return v.toDate();
  if (v is String) return DateTime.tryParse(v) ?? fallback;
  return fallback;
}

class SongEntry {
  final String id;
  String title;
  String artist;
  bool done;
  final DateTime createdAt;

  /// When this entry was last changed (the newer side wins when two devices
  /// changed the same entry).
  DateTime updatedAt;

  /// Position in the list: the newest is on top. Adding or checking an entry
  /// moves it to the top.
  DateTime sortAt;

  SongEntry({
    required this.id,
    required this.title,
    this.artist = '',
    this.done = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? sortAt,
  }) : createdAt = createdAt ?? _nowMs(),
       updatedAt = updatedAt ?? createdAt ?? _nowMs(),
       sortAt = sortAt ?? createdAt ?? _nowMs();

  String get subtitle => artist.trim();

  String get searchQuery =>
      [title, artist].where((e) => e.trim().isNotEmpty).join(' ');

  String get key =>
      '${title.trim().toLowerCase()}\u0001${artist.trim().toLowerCase()}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'done': done,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'sortAt': sortAt.toIso8601String(),
  };

  factory SongEntry.fromJson(Map<String, dynamic> j) {
    final created =
        DateTime.tryParse(j['createdAt'] as String? ?? '') ?? _nowMs();
    return SongEntry(
      id: j['id'] as String,
      title: j['title'] as String? ?? '',
      artist: j['artist'] as String? ?? '',
      done: j['done'] as bool? ?? false,
      createdAt: created,
      updatedAt: _timeOf(j['updatedAt'], created),
      sortAt: _timeOf(j['sortAt'], created),
    );
  }

  /// The document in users/{uid}/songList/{id}.
  Map<String, dynamic> toFirestore() => {
    'title': title,
    'artist': artist,
    'done': done,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'sortAt': sortAt.millisecondsSinceEpoch,
    'device': Platform.localHostname,
  };

  factory SongEntry.fromFirestore(String id, Map<String, dynamic> m) {
    final created = _timeOf(m['createdAt'], _nowMs());
    return SongEntry(
      id: id,
      title: (m['title'] as String?) ?? '',
      artist: (m['artist'] as String?) ?? '',
      done: (m['done'] as bool?) ?? false,
      createdAt: created,
      updatedAt: _timeOf(m['updatedAt'], created),
      sortAt: _timeOf(m['sortAt'], created),
    );
  }
}

/// One change waiting to be sent to the cloud: "this entry is new/changed"
/// (the current entry is sent) or "this entry was deleted".
class _ListOp {
  final bool remove;
  final DateTime at;
  _ListOp.upsert() : remove = false, at = _nowMs();
  _ListOp.remove() : remove = true, at = _nowMs();
  _ListOp._(this.remove, this.at);

  Map<String, dynamic> toJson() => {
    'remove': remove,
    'at': at.toIso8601String(),
  };

  factory _ListOp.fromJson(Map<String, dynamic> m) =>
      _ListOp._(m['remove'] == true, _timeOf(m['at'], _nowMs()));
}

/// The song list, kept in sync with the cloud (users/{uid}/songList).
///
/// Offline first: every change is applied here at once, written to a queue on
/// this phone, and the queue is sent to Firestore whenever there is
/// internet. Whatever other devices changed (added, deleted, checked) is
/// merged in as it arrives. There is no separate cloud list: both sides are
/// made equal.
class SongListStore extends ChangeNotifier {
  static const _prefsKey = 'palm_tunes_song_list';
  static const _probeHost = 'firestore.googleapis.com';
  static const _settle = Duration(seconds: 30);

  final List<SongEntry> _items = [];

  List<SongEntry> get pending => _items.where((e) => !e.done).toList();
  List<SongEntry> get completed => _items.where((e) => e.done).toList();
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  // ---- sync state
  AuthStore? _auth;
  SharedPreferences? _prefs;
  String? _uid;
  final Map<String, _ListOp> _queue = {};

  /// Entries that were in the cloud at some point. One that is here, but no
  /// longer in the cloud, was deleted on another device.
  final Set<String> _synced = {};
  // Ids just sent: a late snapshot from before the send must not undo it.
  final Map<String, DateTime> _recentUp = {};
  final Map<String, DateTime> _recentDel = {};
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  Timer? _timer;
  bool _online = true;
  bool _flushing = false;
  bool _wasEnabled = false;
  bool _disposed = false;
  DateTime? _lastSynced;

  bool get syncEnabled => _uid != null && (_auth?.cloudSaving ?? false);
  bool get online => _online;
  bool get syncing => _flushing;
  int get pendingCount => _queue.length;
  DateTime? get lastSynced => _lastSynced;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      var legacy = false;
      _items.clear();
      for (final e in list) {
        final m = Map<String, dynamic>.from(e as Map);
        if (m['sortAt'] == null) legacy = true;
        _items.add(SongEntry.fromJson(m));
      }
      if (legacy) {
        // A list saved before syncing existed: keep its order.
        final base = _nowMs();
        for (var i = 0; i < _items.length; i++) {
          _items[i].sortAt = base.subtract(Duration(milliseconds: i * 1000));
        }
      }
      _sort();
    } catch (_) {}
    notifyListeners();
  }

  void _sort() {
    _items.sort((a, b) {
      final c = b.sortAt.compareTo(a.sortAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  }

  Future<void> _save() async {
    final prefs = _prefs ?? await SharedPreferences.getInstance();
    _prefs = prefs;
    await prefs.setString(
      _prefsKey,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  void _commit() {
    notifyListeners();
    _save();
    _persistQueue();
    unawaited(flush());
  }

  // ---------------------------------------------------------------------
  // Changes made on this phone
  // ---------------------------------------------------------------------

  void _queueUpsert(String id) {
    if (_uid == null) return;
    _queue[id] = _ListOp.upsert();
  }

  void _queueRemove(String id) {
    if (_uid == null) return;
    _queue[id] = _ListOp.remove();
  }

  bool exists(String title, String artist, {String? exceptId}) {
    final t = title.trim().toLowerCase();
    final a = artist.trim().toLowerCase();
    return _items.any(
      (e) =>
          e.id != exceptId &&
          e.title.trim().toLowerCase() == t &&
          e.artist.trim().toLowerCase() == a,
    );
  }

  void add({required String title, String artist = ''}) {
    final now = _nowMs();
    final e = SongEntry(
      id: const Uuid().v4(),
      title: title.trim(),
      artist: artist.trim(),
      createdAt: now,
      updatedAt: now,
      sortAt: now,
    );
    _items.insert(0, e);
    _queueUpsert(e.id);
    _commit();
  }

  void update(String id, {required String title, required String artist}) {
    final i = _items.indexWhere((e) => e.id == id);
    if (i == -1) return;
    _items[i]
      ..title = title.trim()
      ..artist = artist.trim()
      ..updatedAt = _nowMs();
    _queueUpsert(id);
    _commit();
  }

  void toggle(String id) {
    final i = _items.indexWhere((e) => e.id == id);
    if (i == -1) return;
    final entry = _items[i];
    final now = _nowMs();
    entry
      ..done = !entry.done
      ..updatedAt = now
      ..sortAt = now;
    _sort();
    _queueUpsert(id);
    _commit();
  }

  void checkAll() => _setAll(true);
  void uncheckAll() => _setAll(false);

  void _setAll(bool done) {
    final now = _nowMs();
    var changed = false;
    for (final e in _items) {
      if (e.done == done) continue;
      e
        ..done = done
        ..updatedAt = now;
      _queueUpsert(e.id);
      changed = true;
    }
    if (changed) _commit();
  }

  void _removeWhere(bool Function(SongEntry e) test) {
    final gone = _items.where(test).toList();
    if (gone.isEmpty) return;
    for (final e in gone) {
      _queueRemove(e.id);
    }
    _items.removeWhere(test);
    _commit();
  }

  void remove(String id) => _removeWhere((e) => e.id == id);
  void clearCompleted() => _removeWhere((e) => e.done);
  void clearAll() => _removeWhere((_) => true);

  // ---------------------------------------------------------------------
  // Account
  // ---------------------------------------------------------------------

  Future<void> attach(AuthStore auth) async {
    _auth = auth;
    _prefs ??= await SharedPreferences.getInstance();
    auth.addListener(_onAuth);
    _onAuth();
  }

  void _onAuth() {
    final auth = _auth;
    if (auth == null) return;
    final uid = auth.status == AuthStatus.signedIn ? auth.uid : null;
    if (uid != _uid) {
      _unbind();
      if (uid != null) _bind(uid);
    }
    final nowEnabled = syncEnabled;
    if (nowEnabled) {
      if (_sub == null) _subscribe();
      if (!_wasEnabled) unawaited(flush());
    } else {
      _sub?.cancel();
      _sub = null;
    }
    _wasEnabled = nowEnabled;
    notifyListeners();
  }

  void _bind(String uid) {
    _uid = uid;
    _queue.clear();
    _synced.clear();
    final p = _prefs;
    if (p != null) {
      try {
        for (final e
            in (jsonDecode(p.getString('pt_lq_$uid') ?? '[]') as List)) {
          final m = Map<String, dynamic>.from(e as Map);
          _queue[m['id'] as String] = _ListOp.fromJson(
            Map<String, dynamic>.from(m['op'] as Map),
          );
        }
        _synced.addAll(p.getStringList('pt_ls_$uid') ?? const []);
        _lastSynced = DateTime.tryParse(p.getString('pt_ll_$uid') ?? '');
      } catch (e) {
        debugPrint('[PalmTunes] List cache read failed -> $e');
      }
    }
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
    _queue.clear();
    _synced.clear();
    _recentUp.clear();
    _recentDel.clear();
    _lastSynced = null;
  }

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('songList');

  void _subscribe() {
    final uid = _uid;
    if (uid == null || !syncEnabled) return;
    _sub?.cancel();
    _sub = _col(uid)
        .snapshots(includeMetadataChanges: true)
        .listen(
          _onSnapshot,
          onError: (Object e) {
            debugPrint('[PalmTunes] List listener stopped -> $e');
            _sub = null;
          },
        );
  }

  // ---------------------------------------------------------------------
  // What other devices changed
  // ---------------------------------------------------------------------

  bool _recent(Map<String, DateTime> m, String id) {
    final t = m[id];
    if (t == null) return false;
    if (DateTime.now().difference(t) > _settle) {
      m.remove(id);
      return false;
    }
    return true;
  }

  void _onSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    if (!syncEnabled) return;
    // Only an answer from the server can say that something is NOT in the
    // cloud; a (possibly old or empty) local cache never deletes anything.
    final server = !snap.metadata.isFromCache;
    final cloud = <String, SongEntry>{};
    for (final d in snap.docs) {
      try {
        cloud[d.id] = SongEntry.fromFirestore(d.id, d.data());
      } catch (_) {}
    }
    var changed = false;
    var queueChanged = false;

    // 1) The cloud has it: add it here, or take the newer side.
    for (final c in cloud.values) {
      final op = _queue[c.id];
      if (op != null && op.remove) {
        // Deleted here and waiting to be deleted there; unless somebody
        // changed it after that.
        if (c.updatedAt.isAfter(op.at)) {
          _queue.remove(c.id);
          queueChanged = true;
        } else {
          continue;
        }
      }
      if (_recent(_recentDel, c.id) &&
          !c.updatedAt.isAfter(_recentDel[c.id]!)) {
        continue; // a late snapshot from before our delete
      }
      final i = _items.indexWhere((e) => e.id == c.id);
      if (i == -1) {
        // The same song added on two devices: one entry is enough.
        final dup = _items.indexWhere((e) => e.key == c.key);
        if (dup != -1) {
          final d = _items.removeAt(dup);
          if (_queue.remove(d.id) != null) queueChanged = true;
        }
        _items.add(c);
        changed = true;
      } else {
        final local = _items[i];
        if (c.updatedAt.isAfter(local.updatedAt)) {
          _items[i] = c; // newer in the cloud
          if (_queue.remove(c.id) != null) queueChanged = true;
          changed = true;
        } else if (server &&
            c.updatedAt.isBefore(local.updatedAt) &&
            _queue[c.id] == null) {
          _queueUpsert(c.id); // newer here and not sent yet: send it
          queueChanged = true;
        }
      }
    }

    // 2) The cloud does not have it.
    if (server) {
      for (final local in List<SongEntry>.of(_items)) {
        if (cloud.containsKey(local.id)) continue;
        if (_queue[local.id] != null) continue; // waiting to be sent
        if (_recent(_recentUp, local.id)) continue; // late snapshot
        if (_synced.contains(local.id)) {
          // It was in the cloud and is gone: deleted on another device.
          _items.removeWhere((e) => e.id == local.id);
          changed = true;
        } else if (cloud.values.any((c) => c.key == local.key)) {
          _items.removeWhere((e) => e.id == local.id); // same song, same list
          changed = true;
        } else {
          _queueUpsert(local.id); // never uploaded: add it to the cloud
          queueChanged = true;
        }
      }
      _synced
        ..addAll(cloud.keys)
        ..removeWhere(
          (id) => !cloud.containsKey(id) && !_items.any((e) => e.id == id),
        );
      _persistSynced();
    }

    if (changed) {
      _sort();
      _save();
    }
    if (queueChanged) {
      _persistQueue();
      unawaited(flush());
    }
    if (server && _queue.isEmpty) _markSynced();
    notifyListeners();
  }

  void _markSynced() {
    final uid = _uid;
    if (uid == null) return;
    _lastSynced = DateTime.now();
    _prefs?.setString('pt_ll_$uid', _lastSynced!.toIso8601String());
  }

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
    if (!await _probe()) return;
    if (syncEnabled && _sub == null) _subscribe();
    await flush();
  }

  /// Sends whatever is waiting. Silent: with no internet it simply returns,
  /// the queue stays and the next attempt happens by itself.
  Future<void> flush() async {
    if (_flushing || !syncEnabled || _queue.isEmpty) return;
    _flushing = true;
    var failed = false;
    try {
      if (!await _probe()) return;
      final uid = _uid;
      if (uid == null) return;
      notifyListeners();
      final ids = _queue.keys.toList();
      for (var s = 0; s < ids.length; s += 400) {
        final chunk = ids.sublist(s, min(s + 400, ids.length));
        final batch = FirebaseFirestore.instance.batch();
        final sent = <String, _ListOp>{};
        for (final id in chunk) {
          final op = _queue[id];
          if (op == null) continue;
          final ref = _col(uid).doc(id);
          if (op.remove) {
            batch.delete(ref);
            sent[id] = op;
          } else {
            final i = _items.indexWhere((e) => e.id == id);
            if (i == -1) {
              _queue.remove(id);
              continue;
            }
            batch.set(ref, _items[i].toFirestore(), SetOptions(merge: true));
            sent[id] = op;
          }
        }
        if (sent.isEmpty) continue;
        try {
          await batch.commit().timeout(const Duration(seconds: 20));
        } catch (e) {
          debugPrint('[PalmTunes] List send failed, will retry -> $e');
          failed = true;
          break;
        }
        final now = DateTime.now();
        for (final e in sent.entries) {
          if (identical(_queue[e.key], e.value)) _queue.remove(e.key);
          if (e.value.remove) {
            _synced.remove(e.key);
            _recentDel[e.key] = now;
          } else {
            _synced.add(e.key);
            _recentUp[e.key] = now;
          }
        }
        _persistQueue();
        _persistSynced();
      }
    } finally {
      _flushing = false;
      if (!failed && _queue.isEmpty && _uid != null) _markSynced();
      notifyListeners();
    }
  }

  void _persistQueue() {
    final uid = _uid;
    if (uid == null) return;
    _prefs?.setString(
      'pt_lq_$uid',
      jsonEncode([
        for (final e in _queue.entries) {'id': e.key, 'op': e.value.toJson()},
      ]),
    );
  }

  void _persistSynced() {
    final uid = _uid;
    if (uid == null) return;
    _prefs?.setStringList('pt_ls_$uid', _synced.toList());
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
    _auth?.removeListener(_onAuth);
    super.dispose();
  }
}

List<int> buildSongWorkbook(List<SongEntry> songs) {
  final excel = xl.Excel.createExcel();
  final first = excel.getDefaultSheet() ?? 'Sheet1';
  excel.rename(first, 'Songs');
  final sheet = excel['Songs'];

  final headerStyle = xl.CellStyle(
    bold: true,
    backgroundColorHex: xl.ExcelColor.fromHexString('#E11D48'),
    fontColorHex: xl.ExcelColor.fromHexString('#FFFFFF'),
  );

  const headers = ['#', 'Song', 'Movie / Artist', 'Status'];
  sheet.appendRow(headers.map((h) => xl.TextCellValue(h)).toList());
  for (var c = 0; c < headers.length; c++) {
    sheet
            .cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0))
            .cellStyle =
        headerStyle;
  }

  for (var i = 0; i < songs.length; i++) {
    final s = songs[i];
    sheet.appendRow([
      xl.IntCellValue(i + 1),
      xl.TextCellValue(s.title),
      xl.TextCellValue(s.artist.isEmpty ? '-' : s.artist),
      xl.TextCellValue(s.done ? 'Checked' : 'Pending'),
    ]);
  }

  sheet.setColumnWidth(0, 6);
  sheet.setColumnWidth(1, 42);
  sheet.setColumnWidth(2, 32);
  sheet.setColumnWidth(3, 12);

  final bytes = excel.encode();
  if (bytes == null) throw StateError('Could not encode workbook');
  return bytes;
}

// ===========================================================================
// Screen
// ===========================================================================

Future<bool> _confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
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
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: const TextStyle(
                color: Colors.white70,
                height: 1.4,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(confirmLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  return result ?? false;
}

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});

  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  final _titleCtrl = TextEditingController();
  final _artistCtrl = TextEditingController();
  final _titleFocus = FocusNode();
  bool _exporting = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _artistCtrl.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final store = context.read<SongListStore>();
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _titleFocus.requestFocus();
      Notch.show('Type a song name first', icon: Icons.edit_note_rounded);
      return;
    }
    if (store.exists(title, _artistCtrl.text)) {
      Notch.show(
        '"$title" is already in your list',
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    store.add(title: title, artist: _artistCtrl.text);
    _titleCtrl.clear();
    _artistCtrl.clear();
    _titleFocus.requestFocus();
  }

  String _dateStamp() {
    final d = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _export() async {
    if (_exporting) return;
    final store = context.read<SongListStore>();
    final songs = [...store.pending, ...store.completed];
    if (songs.isEmpty) {
      Notch.show('Your list is empty', icon: Icons.info_outline_rounded);
      return;
    }
    setState(() => _exporting = true);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/Palm_Tunes_List_${_dateStamp()}.xlsx');
      await file.writeAsBytes(buildSongWorkbook(songs), flush: true);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              file.path,
              mimeType:
                  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
              name: 'Palm_Tunes_List_${_dateStamp()}.xlsx',
            ),
          ],
          fileNameOverrides: ['Palm_Tunes_List_${_dateStamp()}.xlsx'],
          subject: 'Palm Tunes song list',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (e) {
      debugPrint('[PalmTunes] Export failed -> $e');
      final why = '$e'.replaceAll('\n', ' ');
      Notch.show(
        'Export failed: ${why.length > 60 ? why.substring(0, 60) : why}',
        icon: Icons.error_outline_rounded,
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _menu(String action, int pending, int done) async {
    final store = context.read<SongListStore>();
    switch (action) {
      case 'export':
        await _export();
      case 'check':
        if (pending > 0 &&
            await _confirmAction(
              context,
              title: 'Check all?',
              message: 'Mark all $pending pending songs as checked?',
              confirmLabel: 'Check all',
            )) {
          store.checkAll();
        }
      case 'uncheck':
        if (done > 0 &&
            await _confirmAction(
              context,
              title: 'Uncheck all?',
              message: 'Move all $done checked songs back to pending?',
              confirmLabel: 'Uncheck all',
            )) {
          store.uncheckAll();
        }
      case 'clear_done':
        if (done > 0 &&
            await confirmDelete(
              context,
              title: 'Clear checked songs?',
              message:
                  'This will permanently delete $done checked songs from your list.',
              confirmLabel: 'Clear',
            )) {
          store.clearCompleted();
        }
      case 'clear_all':
        if (store.length > 0 &&
            await confirmDelete(
              context,
              title: 'Clear entire list?',
              message:
                  'Delete all ${store.length} songs from your list? This cannot be undone.',
              confirmLabel: 'Clear list',
            )) {
          store.clearAll();
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SongListStore>();
    final accent = Theme.of(context).colorScheme.primary;
    final pending = store.pending;
    final completed = store.completed;
    final meter = context.read<BassMeter>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              BassLogo(level: meter.level, color: accent, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Palm Tunes',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                    Text(
                      store.isEmpty
                          ? 'Your song list'
                          : '${pending.length} pending · ${completed.length} checked',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const _SyncChip(),
              if (_exporting)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  icon: const Icon(
                    Icons.more_vert_rounded,
                    color: Colors.white70,
                  ),
                  color: AppColors.surface,
                  onSelected: (a) => _menu(a, pending.length, completed.length),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'export',
                      enabled: !store.isEmpty,
                      child: const Text('Export to Excel'),
                    ),
                    PopupMenuItem(
                      value: 'check',
                      enabled: pending.isNotEmpty,
                      child: const Text('Check all'),
                    ),
                    PopupMenuItem(
                      value: 'uncheck',
                      enabled: completed.isNotEmpty,
                      child: const Text('Uncheck all'),
                    ),
                    PopupMenuItem(
                      value: 'clear_done',
                      enabled: completed.isNotEmpty,
                      child: const Text('Clear checked'),
                    ),
                    PopupMenuItem(
                      value: 'clear_all',
                      enabled: !store.isEmpty,
                      child: const Text('Clear entire list'),
                    ),
                  ],
                ),
            ],
          ),
          const SizedBox(height: 12),
          GlassContainer(
            borderRadius: 18,
            padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    children: [
                      TextField(
                        controller: _titleCtrl,
                        focusNode: _titleFocus,
                        textInputAction: TextInputAction.next,
                        textCapitalization: TextCapitalization.words,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14.5,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Song name',
                          hintStyle: TextStyle(color: Colors.white38),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 11),
                        ),
                      ),
                      const Divider(height: 1, color: Colors.white10),
                      TextField(
                        controller: _artistCtrl,
                        textInputAction: TextInputAction.done,
                        textCapitalization: TextCapitalization.words,
                        onSubmitted: (_) => _submit(),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13.5,
                        ),
                        decoration: const InputDecoration(
                          hintText: 'Movie or artist (optional)',
                          hintStyle: TextStyle(color: Colors.white30),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  width: 48,
                  child: FilledButton(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Icon(Icons.add_rounded),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: store.isEmpty
                ? const _EmptyList()
                : ListView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.only(bottom: 170),
                    children: [
                      _SectionHeader(
                        icon: Icons.radio_button_unchecked_rounded,
                        label: 'Pending',
                        count: pending.length,
                      ),
                      if (pending.isEmpty)
                        const _Hint('All caught up. Every song is checked.'),
                      for (final e in pending)
                        _SongTile(key: ValueKey(e.id), entry: e),
                      const SizedBox(height: 16),
                      _SectionHeader(
                        icon: Icons.check_circle_rounded,
                        label: 'Checked',
                        count: completed.length,
                      ),
                      if (completed.isEmpty)
                        const _Hint('Check a song above to move it here.'),
                      for (final e in completed)
                        _SongTile(key: ValueKey(e.id), entry: e),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final int count;
  const _SectionHeader({
    required this.icon,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2),
      child: Row(
        children: [
          Icon(icon, size: 17, color: accent),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 14.5,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count',
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 2),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white38, fontSize: 12.5),
    ),
  );
}

class _EmptyList extends StatelessWidget {
  const _EmptyList();

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
              child: Icon(Icons.queue_music_rounded, color: accent, size: 32),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your list is empty',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Add songs you want to find. Tap one later to search it.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  final SongEntry entry;
  const _SongTile({super.key, required this.entry});

  Future<void> _edit(BuildContext context) async {
    final store = context.read<SongListStore>();
    final title = TextEditingController(text: entry.title);
    final artist = TextEditingController(text: entry.artist);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
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
              const Text(
                'Edit song',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: title,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(hintText: 'Song name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: artist,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(hintText: 'Movie or artist'),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    final newTitle = title.text.trim();
    final newArtist = artist.text.trim();
    title.dispose();
    artist.dispose();
    if (saved != true || newTitle.isEmpty) return;
    if (store.exists(newTitle, newArtist, exceptId: entry.id)) {
      Notch.show(
        '"$newTitle" is already in your list',
        icon: Icons.info_outline_rounded,
      );
      return;
    }
    store.update(entry.id, title: newTitle, artist: newArtist);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<SongListStore>();
    final accent = Theme.of(context).colorScheme.primary;
    return Dismissible(
      key: ValueKey('dismiss-${entry.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => confirmDelete(
        context,
        title: 'Delete song?',
        message: '"${entry.title}" will be removed from your list.',
        confirmLabel: 'Delete',
      ),
      onDismissed: (_) => store.remove(entry.id),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.redAccent.shade200.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          Icons.delete_outline_rounded,
          color: Colors.redAccent.shade200,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () =>
                context.read<NavController>().searchFor(entry.searchQuery),
            onLongPress: () => _edit(context),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: Colors.white.withValues(alpha: entry.done ? 0.03 : 0.06),
                border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
              ),
              padding: const EdgeInsets.fromLTRB(4, 6, 12, 6),
              child: Row(
                children: [
                  Checkbox(
                    value: entry.done,
                    onChanged: (_) => store.toggle(entry.id),
                    shape: const CircleBorder(),
                    side: BorderSide(
                      color: accent.withValues(alpha: 0.7),
                      width: 1.6,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: entry.done ? Colors.white38 : Colors.white,
                            decoration: entry.done
                                ? TextDecoration.lineThrough
                                : null,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (entry.subtitle.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              entry.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.search_rounded,
                    color: Colors.white30,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small cloud status in the header: synced, syncing, or offline with the
/// number of changes waiting to be sent.
class _SyncChip extends StatelessWidget {
  const _SyncChip();

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SongListStore>();
    if (!store.syncEnabled) return const SizedBox.shrink();
    final n = store.pendingCount;
    final IconData icon;
    final String label;
    final Color color;
    if (!store.online) {
      icon = Icons.cloud_off_rounded;
      label = n > 0 ? 'Offline · $n' : 'Offline';
      color = Colors.amberAccent.shade200;
    } else if (n > 0 || store.syncing) {
      icon = Icons.cloud_sync_rounded;
      label = n > 0 ? 'Syncing · $n' : 'Syncing';
      color = Colors.white60;
    } else {
      icon = Icons.cloud_done_rounded;
      label = 'Synced';
      color = Colors.greenAccent.shade200;
    }
    return Container(
      margin: const EdgeInsets.only(right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
