import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart' as xl;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'bass_meter.dart';
import 'player_hub.dart';
import 'search.dart';
import 'ui.dart';

class SongEntry {
  final String id;
  String title;
  String artist;
  bool done;
  final DateTime createdAt;

  SongEntry({
    required this.id,
    required this.title,
    this.artist = '',
    this.done = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String get subtitle => artist.trim();

  String get searchQuery =>
      [title, artist].where((e) => e.trim().isNotEmpty).join(' ');

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'done': done,
    'createdAt': createdAt.toIso8601String(),
  };

  factory SongEntry.fromJson(Map<String, dynamic> j) => SongEntry(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    done: j['done'] as bool? ?? false,
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? ''),
  );
}

class SongListStore extends ChangeNotifier {
  static const _prefsKey = 'palm_tunes_song_list';
  final List<SongEntry> _items = [];

  List<SongEntry> get pending => _items.where((e) => !e.done).toList();
  List<SongEntry> get completed => _items.where((e) => e.done).toList();
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      _items
        ..clear()
        ..addAll(
          list.map(
            (e) => SongEntry.fromJson(Map<String, dynamic>.from(e as Map)),
          ),
        );
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_items.map((e) => e.toJson()).toList()),
    );
  }

  void _commit() {
    notifyListeners();
    _save();
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
    _items.insert(
      0,
      SongEntry(
        id: const Uuid().v4(),
        title: title.trim(),
        artist: artist.trim(),
      ),
    );
    _commit();
  }

  void update(String id, {required String title, required String artist}) {
    final i = _items.indexWhere((e) => e.id == id);
    if (i == -1) return;
    _items[i]
      ..title = title.trim()
      ..artist = artist.trim();
    _commit();
  }

  void toggle(String id) {
    final i = _items.indexWhere((e) => e.id == id);
    if (i == -1) return;
    final entry = _items.removeAt(i);
    entry.done = !entry.done;
    _items.insert(0, entry);
    _commit();
  }

  void checkAll() {
    if (!_items.any((e) => !e.done)) return;
    for (final e in _items) {
      e.done = true;
    }
    _commit();
  }

  void uncheckAll() {
    if (!_items.any((e) => e.done)) return;
    for (final e in _items) {
      e.done = false;
    }
    _commit();
  }

  void remove(String id) {
    _items.removeWhere((e) => e.id == id);
    _commit();
  }

  void clearCompleted() {
    _items.removeWhere((e) => e.done);
    _commit();
  }

  void clearAll() {
    if (_items.isEmpty) return;
    _items.clear();
    _commit();
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
      final file = File('${dir.path}/Palm Tunes List ${_dateStamp()}.xlsx');
      await file.writeAsBytes(buildSongWorkbook(songs), flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], subject: 'Palm Tunes song list'),
      );
    } catch (e) {
      debugPrint('[PalmTunes] Export failed -> $e');
      Notch.show(
        'Could not export the list',
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
