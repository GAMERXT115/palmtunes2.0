import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'search.dart';

abstract class YtFriendlyError implements Exception {
  String get message;
}

class YtRateLimited implements YtFriendlyError {
  final Duration retryIn;
  YtRateLimited(this.retryIn);

  @override
  String get message {
    final mins = (retryIn.inSeconds / 60).ceil().clamp(1, 60);
    return 'YouTube is rate limiting this network. Try again in about $mins min.';
  }

  @override
  String toString() => message;
}

class YtSignInRequired implements YtFriendlyError {
  final bool hasCookies;
  YtSignInRequired(this.hasCookies);

  @override
  String get message => hasCookies
      ? 'YouTube is blocking this network right now. Try again later, or switch to another connection.'
      : 'YouTube wants a sign-in. Add your cookie line to cookies.txt.';

  @override
  String toString() => message;
}

class _CookieClient extends http.BaseClient {
  static const String _origin = 'https://www.youtube.com';

  final http.Client _inner = http.Client();
  final String cookie;
  final Map<String, String> _values;

  _CookieClient(this.cookie) : _values = _parse(cookie);

  static Map<String, String> _parse(String cookie) {
    final map = <String, String>{};
    for (final part in cookie.split(';')) {
      final kv = part.trim();
      final i = kv.indexOf('=');
      if (i <= 0) continue;
      map[kv.substring(0, i)] = kv.substring(i + 1);
    }
    return map;
  }

  String? _authorization() {
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String sign(String label, String? value) {
      if (value == null || value.isEmpty) return '';
      final hash = sha1.convert(utf8.encode('$ts $value $_origin'));
      return '$label ${ts}_$hash';
    }

    final parts = [
      sign('SAPISIDHASH', _values['SAPISID'] ?? _values['__Secure-3PAPISID']),
      sign('SAPISID1PHASH', _values['__Secure-1PAPISID']),
      sign('SAPISID3PHASH', _values['__Secure-3PAPISID']),
    ].where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(' ');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final host = request.url.host;
    final isYoutube =
        host.endsWith('youtube.com') || host.endsWith('google.com');
    if (cookie.isNotEmpty && isYoutube) {
      final existing = request.headers['cookie'];
      request.headers['cookie'] = existing == null || existing.isEmpty
          ? cookie
          : '$existing; $cookie';
      if (request.url.path.startsWith('/youtubei/')) {
        final auth = _authorization();
        if (auth != null) {
          request.headers['authorization'] = auth;
          request.headers['x-origin'] = _origin;
          request.headers['x-goog-authuser'] = '0';
        }
      }
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

class _ClientSpec {
  final String name;
  final yt.YoutubeApiClient client;
  final bool useAuth;
  const _ClientSpec(this.name, this.client, this.useAuth);
}

class PlaybackSource {
  final String video;
  final String? audio;
  final int? height;
  final Map<String, String> headers;
  const PlaybackSource(this.video, this.audio, this.height, this.headers);
}

class DownloadSource {
  final String videoUrl;
  final String audioUrl;
  final int videoLength;
  final int audioLength;
  final bool videoMp4;
  final bool audioMp4;
  final int height;
  final Map<String, String> headers;

  const DownloadSource({
    required this.videoUrl,
    required this.audioUrl,
    required this.videoLength,
    required this.audioLength,
    required this.videoMp4,
    required this.audioMp4,
    required this.height,
    required this.headers,
  });

  int get totalBytes => videoLength + audioLength;
  String get videoExt => videoMp4 ? 'mp4' : 'webm';
  String get audioExt => audioMp4 ? 'm4a' : 'webm';
  String get mergedExt => videoMp4 && audioMp4 ? 'mp4' : 'mkv';
}

class _Fmt {
  final String url;
  final String mime;
  final int bitrate;
  final int height;
  final int fps;
  final int length;

  const _Fmt(
    this.url,
    this.mime,
    this.bitrate,
    this.height,
    this.fps,
    this.length,
  );

  bool get isVideo => mime.startsWith('video/');
  bool get isAudio => mime.startsWith('audio/');
  bool get isMp4 => mime.contains('/mp4');

  String get codec {
    final m = RegExp(r'codecs="([^"]+)"').firstMatch(mime);
    return m?.group(1) ?? '';
  }

  static _Fmt? parse(dynamic raw) {
    if (raw is! Map) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    return _Fmt(
      url,
      raw['mimeType'] as String? ?? '',
      (raw['bitrate'] as num?)?.toInt() ?? 0,
      (raw['height'] as num?)?.toInt() ?? 0,
      (raw['fps'] as num?)?.toInt() ?? 0,
      int.tryParse('${raw['contentLength'] ?? ''}') ?? 0,
    );
  }
}

class YtStreams {
  YtStreams._();

  static final YtStreams instance = YtStreams._();

  static const int maxPlaybackHeight = 1080;
  static const String _androidVersion = '20.10.38';
  static const String _androidParams = '2AMB';
  static const String _musicClientVersion = '1.20250122.01.00';
  static const Duration _innertubeTimeout = Duration(seconds: 10);
  static const Duration _probeTimeout = Duration(seconds: 6);
  static const Duration _hdBlockCooldown = Duration(minutes: 30);
  static const Duration _relatedStepTimeout = Duration(seconds: 8);
  static const Duration _relatedCacheTtl = Duration(minutes: 30);
  static const Duration _chunkTimeout = Duration(seconds: 20);
  static const double _probeAt = 0.6;
  static const int _probeBytes = 4096;
  static const int _relatedLimit = 30;
  static const int _chunkBytes = 10 * 1024 * 1024;
  static const int _chunkRetries = 3;

  static const Map<String, String> _clientUa = {
    'androidSdkless':
        'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
    'androidVr': 'com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    'android':
        'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
    'tv': 'Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version',
  };

  static const Duration _cacheTtl = Duration(hours: 2);
  static const Duration _cooldown = Duration(minutes: 3);

  String _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36 OPR/137.0.0.0';
  final yt.YoutubeExplode _plain = yt.YoutubeExplode();
  final http.Client _http = http.Client();
  yt.YoutubeExplode? _authed;
  String _cookie = '';
  String? _preferred;
  final Map<String, (DateTime, yt.StreamManifest, String)> _cache = {};
  final Map<String, Future<yt.StreamManifest>> _inflight = {};
  final Map<String, (DateTime, PlaybackSource)> _hdCache = {};
  final Map<String, (DateTime, List<YtVideo>)> _relatedCache = {};
  final Set<String> _noHd = {};
  DateTime? _cooldownUntil;
  DateTime? _hdBlockedUntil;

  yt.YoutubeExplode get client => _plain;
  bool get hasCookies => _cookie.isNotEmpty;

  Duration? get cooldownRemaining {
    final until = _cooldownUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? null : left;
  }

  void setBrowserUserAgent(String ua) {
    final v = ua.trim();
    if (v.isNotEmpty) _browserUa = v;
  }

  static String normalizeCookies(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '';
    if (t.contains('\t')) {
      final pairs = <String>[];
      for (final line in t.split(RegExp(r'\r?\n'))) {
        var l = line.trim();
        if (l.startsWith('#HttpOnly_')) l = l.substring(10);
        if (l.isEmpty || l.startsWith('#')) continue;
        final parts = l.split('\t');
        if (parts.length < 7) continue;
        if (!parts[0].contains('youtube.com')) continue;
        pairs.add('${parts[5]}=${parts[6]}');
      }
      return pairs.join('; ');
    }
    return t
        .replaceFirst(RegExp(r'^cookie:\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'[\r\n]+'), ' ')
        .trim();
  }

  void setCookies(String raw) {
    final c = normalizeCookies(raw);
    if (c == _cookie) return;
    _cookie = c;
    final old = _authed;
    _authed = c.isEmpty
        ? null
        : yt.YoutubeExplode(httpClient: yt.YoutubeHttpClient(_CookieClient(c)));
    old?.close();
    _cache.clear();
    _hdCache.clear();
    _cooldownUntil = null;
    _preferred = null;
    debugPrint(
      '[PalmTunes] Cookies ${c.isEmpty ? 'cleared' : 'set (${c.split(';').length} values)'}',
    );
  }

  Map<String, String> headersFor(String videoId) {
    final clientName = _cache[videoId]?.$3;
    return {'User-Agent': _clientUa[clientName] ?? _browserUa};
  }

  List<_ClientSpec> get _specs => [
    const _ClientSpec(
      'androidSdkless',
      yt.YoutubeApiClient.androidSdkless,
      false,
    ),
    const _ClientSpec('androidVr', yt.YoutubeApiClient.androidVr, false),
    _ClientSpec('tv', yt.YoutubeApiClient.tv, hasCookies),
    const _ClientSpec('android', yt.YoutubeApiClient.android, false),
  ];

  List<_ClientSpec> get _chain {
    final base = _specs;
    final pref = _preferred;
    if (pref == null) return base;
    return [
      ...base.where((e) => e.name == pref),
      ...base.where((e) => e.name != pref),
    ];
  }

  Future<yt.StreamManifest> manifest(String videoId) {
    final cached = _cache[videoId];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return Future.value(cached.$2);
    }
    return _inflight[videoId] ??= _fetch(videoId)
        .whenComplete(() => _inflight.remove(videoId));
  }

  Future<yt.StreamManifest> _fetch(String videoId) async {
    final left = cooldownRemaining;
    if (left != null) throw YtRateLimited(left);

    Object? lastError;
    var sawBotCheck = false;
    for (final spec in _chain) {
      final explode = spec.useAuth && _authed != null ? _authed! : _plain;
      try {
        final m = await explode.videos.streamsClient.getManifest(
          videoId,
          ytClients: [spec.client],
          requireWatchPage: false,
        );
        if (m.muxed.isEmpty && m.audioOnly.isEmpty) {
          debugPrint('[PalmTunes] $videoId: ${spec.name} returned no streams');
          continue;
        }
        debugPrint(
          '[PalmTunes] $videoId: manifest via ${spec.name}${spec.useAuth ? ' (signed in)' : ''} (muxed ${m.muxed.length}, video ${m.videoOnly.length}, audio ${m.audioOnly.length})',
        );
        _cache[videoId] = (DateTime.now(), m, spec.name);
        _preferred = spec.name;
        return m;
      } on yt.RequestLimitExceededException {
        _cooldownUntil = DateTime.now().add(_cooldown);
        debugPrint('[PalmTunes] Rate limited by YouTube, pausing requests');
        throw YtRateLimited(_cooldown);
      } catch (e) {
        lastError = e;
        final text = e.toString();
        if (text.contains('Sign in to confirm') || text.contains('not a bot')) {
          sawBotCheck = true;
        }
        final short = text.split('\n').first;
        debugPrint('[PalmTunes] $videoId: ${spec.name} failed -> $short');
      }
    }
    if (sawBotCheck) throw YtSignInRequired(hasCookies);
    throw StateError('No stream available ($lastError)');
  }

  T _highest<T extends yt.StreamInfo>(List<T> list) {
    var best = list.first;
    for (final s in list) {
      if (s.bitrate.bitsPerSecond > best.bitrate.bitsPerSecond) best = s;
    }
    return best;
  }

  static int _codecRank(String codec) {
    final c = codec.toLowerCase();
    if (c.startsWith('avc')) return 0;
    if (c.startsWith('vp9') || c.startsWith('vp09')) return 1;
    return 2;
  }

  Future<(yt.StreamInfo, bool)> bestStream(String videoId) async {
    final m = await manifest(videoId);
    final muxed = m.muxed.toList();
    if (muxed.isNotEmpty) {
      final mp4 = muxed
          .where((s) => s.container == yt.StreamContainer.mp4)
          .toList();
      final yt.StreamInfo pick = _highest(mp4.isNotEmpty ? mp4 : muxed);
      return (pick, false);
    }
    final audio = m.audioOnly.toList();
    if (audio.isEmpty) throw StateError('No playable stream');
    final m4a = audio
        .where((s) => s.container == yt.StreamContainer.mp4)
        .toList();
    final yt.StreamInfo pick = _highest(m4a.isNotEmpty ? m4a : audio);
    return (pick, true);
  }

  Future<Map<String, dynamic>?> _innertubePost(
    String url,
    Map<String, String> headers,
    Map<String, dynamic> body,
  ) async {
    final res = await _http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json', ...headers},
          body: jsonEncode(body),
        )
        .timeout(_innertubeTimeout);
    if (res.statusCode != 200) {
      debugPrint(
        '[PalmTunes] ${Uri.parse(url).path} returned ${res.statusCode}',
      );
      return null;
    }
    final decoded = jsonDecode(res.body);
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  (_Fmt, _Fmt)? _pickFormats(List<dynamic> raw) {
    final formats = raw.map(_Fmt.parse).whereType<_Fmt>().toList();
    final videos = formats
        .where((f) => f.isVideo && f.height > 0)
        .where((f) => f.height <= maxPlaybackHeight)
        .toList();
    final audios = formats.where((f) => f.isAudio).toList();
    if (videos.isEmpty || audios.isEmpty) return null;
    videos.sort((a, b) {
      final h = b.height.compareTo(a.height);
      if (h != 0) return h;
      final c = _codecRank(a.codec).compareTo(_codecRank(b.codec));
      if (c != 0) return c;
      final f = b.fps.compareTo(a.fps);
      if (f != 0) return f;
      return b.bitrate.compareTo(a.bitrate);
    });
    final mp4Audio = audios.where((a) => a.isMp4).toList();
    final pool = mp4Audio.isNotEmpty ? mp4Audio : audios;
    pool.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    return (videos.first, pool.first);
  }

  Future<bool> _probeDeep(_Fmt fmt, String ua) async {
    var start = 0;
    var end = 1;
    if (fmt.length > _probeBytes * 2) {
      start = (fmt.length * _probeAt).floor();
      end = min(start + _probeBytes - 1, fmt.length - 1);
    }
    try {
      final res = await _http
          .get(
            Uri.parse(fmt.url),
            headers: {'User-Agent': ua, 'Range': 'bytes=$start-$end'},
          )
          .timeout(_probeTimeout);
      return res.statusCode == 200 || res.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  Future<(_Fmt, _Fmt, String)?> _androidFormats(String videoId) async {
    final ua = _clientUa['android']!;
    final data = await _innertubePost(
      'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
      {
        'User-Agent': ua,
        'X-YouTube-Client-Name': '3',
        'X-YouTube-Client-Version': _androidVersion,
      },
      {
        'context': {
          'client': {
            'clientName': 'ANDROID',
            'clientVersion': _androidVersion,
            'androidSdkVersion': 30,
            'osName': 'Android',
            'osVersion': '11',
            'hl': 'en',
            'gl': 'US',
          },
        },
        'videoId': videoId,
        'params': _androidParams,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
    );
    if (data == null) return null;
    final status = (data['playabilityStatus'] as Map?)?['status'];
    if (status != 'OK') {
      debugPrint('[PalmTunes] $videoId: HD player status $status');
      return null;
    }
    final adaptive =
        ((data['streamingData'] as Map?)?['adaptiveFormats'] as List?) ??
        const [];
    final pick = _pickFormats(adaptive);
    if (pick == null) {
      debugPrint('[PalmTunes] $videoId: HD response had no usable formats');
      return null;
    }
    return (pick.$1, pick.$2, ua);
  }

  Future<PlaybackSource?> _hdSource(String videoId) async {
    final cached = _hdCache[videoId];
    if (cached != null && DateTime.now().difference(cached.$1) < _cacheTtl) {
      return cached.$2;
    }
    final blocked = _hdBlockedUntil;
    if (blocked != null && DateTime.now().isBefore(blocked)) return null;
    try {
      final res = await _androidFormats(videoId);
      if (res == null) return null;
      final (video, audio, ua) = res;
      final checks = await Future.wait([
        _probeDeep(video, ua),
        _probeDeep(audio, ua),
      ]);
      if (!checks[0] || !checks[1]) {
        _hdBlockedUntil = DateTime.now().add(_hdBlockCooldown);
        debugPrint(
          '[PalmTunes] $videoId: HD streams gated (video ${checks[0] ? 'ok' : 'blocked'}, audio ${checks[1] ? 'ok' : 'blocked'}), using 360p for ${_hdBlockCooldown.inMinutes} min',
        );
        return null;
      }
      debugPrint(
        '[PalmTunes] $videoId: HD ${video.height}p ${video.codec} + audio ${audio.bitrate ~/ 1000} kbps',
      );
      final source = PlaybackSource(video.url, audio.url, video.height, {
        'User-Agent': ua,
      });
      _hdCache[videoId] = (DateTime.now(), source);
      return source;
    } catch (e) {
      debugPrint(
        '[PalmTunes] $videoId: HD request failed -> ${e.toString().split('\n').first}',
      );
      return null;
    }
  }

  Future<PlaybackSource> playbackSource(String videoId) async {
    if (!_noHd.contains(videoId)) {
      final hd = await _hdSource(videoId);
      if (hd != null) return hd;
      _noHd.add(videoId);
      debugPrint('[PalmTunes] $videoId: HD unavailable, using 360p');
    }
    final (info, _) = await bestStream(videoId);
    return PlaybackSource(info.url.toString(), null, null, headersFor(videoId));
  }

  Future<DownloadSource> downloadSource(String videoId) async {
    final left = cooldownRemaining;
    if (left != null) throw YtRateLimited(left);
    (_Fmt, _Fmt, String)? res;
    try {
      res = await _androidFormats(videoId);
    } catch (e) {
      throw StateError('HD request failed (${e.toString().split('\n').first})');
    }
    if (res == null) throw StateError('No HD streams for $videoId');
    final (video, audio, ua) = res;
    debugPrint(
      '[PalmTunes] $videoId: download ${video.height}p ${video.codec} (${video.length} B) + audio ${audio.bitrate ~/ 1000} kbps (${audio.length} B)',
    );
    return DownloadSource(
      videoUrl: video.url,
      audioUrl: audio.url,
      videoLength: video.length,
      audioLength: audio.length,
      videoMp4: video.isMp4,
      audioMp4: audio.isMp4,
      height: video.height,
      headers: {'User-Agent': ua},
    );
  }

  Stream<List<int>> openRanged(
    String url,
    int length,
    Map<String, String> headers,
  ) async* {
    final client = http.Client();
    try {
      if (length <= 0) {
        final req = http.Request('GET', Uri.parse(url))
          ..headers.addAll(headers);
        final res = await client.send(req).timeout(_chunkTimeout);
        if (res.statusCode != 200 && res.statusCode != 206) {
          throw HttpException('HTTP ${res.statusCode}');
        }
        yield* res.stream.timeout(_chunkTimeout);
        return;
      }
      var start = 0;
      var failures = 0;
      while (start < length) {
        final end = min(start + _chunkBytes, length) - 1;
        final before = start;
        try {
          final req = http.Request('GET', Uri.parse(url))
            ..headers.addAll({...headers, 'Range': 'bytes=$start-$end'});
          final res = await client.send(req).timeout(_chunkTimeout);
          if (res.statusCode != 206) {
            unawaited(res.stream.drain<void>().catchError((Object _) {}));
            throw HttpException('HTTP ${res.statusCode}');
          }
          await for (final chunk in res.stream.timeout(_chunkTimeout)) {
            start += chunk.length;
            yield chunk;
          }
          if (start == before) throw const HttpException('Empty chunk');
          failures = 0;
        } catch (e) {
          failures++;
          debugPrint(
            '[PalmTunes] Chunk at $start failed ($failures/$_chunkRetries) -> ${e.toString().split('\n').first}',
          );
          if (failures > _chunkRetries) rethrow;
          await Future.delayed(Duration(milliseconds: 600 * failures));
        }
      }
    } finally {
      client.close();
    }
  }

  void markNoHd(String videoId) {
    _noHd.add(videoId);
    _hdCache.remove(videoId);
  }

  Future<List<YtVideo>> _guard(
    String label,
    Future<List<YtVideo>> Function() run,
  ) async {
    try {
      final list = await run().timeout(_relatedStepTimeout);
      if (list.isEmpty) debugPrint('[PalmTunes] $label returned nothing');
      return list;
    } catch (e) {
      debugPrint(
        '[PalmTunes] $label failed -> ${e.toString().split('\n').first}',
      );
      return const [];
    }
  }

  static Future<List<YtVideo>> _firstNonEmpty(
    List<Future<List<YtVideo>>> futures,
  ) {
    if (futures.isEmpty) return Future.value(const []);
    final done = Completer<List<YtVideo>>();
    var remaining = futures.length;
    for (final f in futures) {
      f.then((list) {
        remaining--;
        if (done.isCompleted) return;
        if (list.isNotEmpty) {
          done.complete(list);
        } else if (remaining == 0) {
          done.complete(const []);
        }
      });
    }
    return done.future;
  }

  List<YtVideo> _clean(Iterable<yt.Video> list, String videoId) {
    final seen = <String>{videoId};
    return list
        .where((v) => !v.isLive && v.duration != null)
        .where((v) => seen.add(v.id.value))
        .map(YtVideo.fromVideo)
        .take(_relatedLimit)
        .toList();
  }

  static void _collect(dynamic node, String key, List<Map> out) {
    if (node is Map) {
      final hit = node[key];
      if (hit is Map) out.add(hit);
      for (final v in node.values) {
        _collect(v, key, out);
      }
    } else if (node is List) {
      for (final v in node) {
        _collect(v, key, out);
      }
    }
  }

  static String _text(dynamic node) {
    if (node is! Map) return '';
    final simple = node['simpleText'];
    if (simple is String) return simple;
    final runs = node['runs'];
    if (runs is! List) return '';
    return runs.map((r) => r is Map ? (r['text'] as String? ?? '') : '').join();
  }

  static String _firstRun(dynamic node) {
    if (node is! Map) return '';
    final runs = node['runs'];
    if (runs is List && runs.isNotEmpty && runs.first is Map) {
      return (runs.first as Map)['text'] as String? ?? '';
    }
    return _text(node);
  }

  static Duration? _parseLength(String text) {
    final parts = text.trim().split(':');
    if (parts.length < 2 || parts.length > 3) return null;
    final nums = parts.map(int.tryParse).toList();
    if (nums.any((n) => n == null)) return null;
    if (nums.length == 2) {
      return Duration(minutes: nums[0]!, seconds: nums[1]!);
    }
    return Duration(hours: nums[0]!, minutes: nums[1]!, seconds: nums[2]!);
  }

  Future<List<YtVideo>> _musicRadio(String videoId) async {
    final data = await _innertubePost(
      'https://music.youtube.com/youtubei/v1/next?prettyPrint=false',
      {
        'User-Agent': _browserUa,
        'Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
        'X-YouTube-Client-Name': '67',
        'X-YouTube-Client-Version': _musicClientVersion,
      },
      {
        'context': {
          'client': {
            'clientName': 'WEB_REMIX',
            'clientVersion': _musicClientVersion,
            'hl': 'en',
            'gl': 'US',
          },
        },
        'videoId': videoId,
        'playlistId': 'RDAMVM$videoId',
        'isAudioOnly': false,
        'enablePersistentPlaylistPanel': true,
      },
    );
    if (data == null) return const [];
    final found = <Map>[];
    _collect(data, 'playlistPanelVideoRenderer', found);
    final seen = <String>{videoId};
    final out = <YtVideo>[];
    for (final r in found) {
      final id = r['videoId'];
      if (id is! String || !seen.add(id)) continue;
      final title = _text(r['title']);
      if (title.isEmpty) continue;
      out.add(
        YtVideo(
          id: id,
          title: title,
          author: _firstRun(r['longBylineText'] ?? r['shortBylineText']),
          duration: _parseLength(_text(r['lengthText'])),
          thumbnailUrl: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        ),
      );
      if (out.length >= _relatedLimit) break;
    }
    return out;
  }

  Future<List<YtVideo>> _relatedVia(yt.YoutubeExplode e, String videoId) async {
    final video = await e.videos.get(videoId);
    final list = await e.videos.getRelatedVideos(video);
    if (list == null) return [];
    return _clean(list, videoId);
  }

  Future<List<YtVideo>> _mixVia(yt.YoutubeExplode e, String videoId) async {
    final videos = await e.playlists
        .getVideos(yt.PlaylistId('RD$videoId'))
        .take(_relatedLimit + 1)
        .toList();
    return _clean(videos, videoId);
  }

  Future<List<YtVideo>> _searchSimilar(
    String videoId,
    String title,
    String author,
  ) async {
    final query = author.isEmpty ? title : '$author $title';
    final results = await _plain.search.search(query);
    return _clean(results, videoId);
  }

  Future<List<YtVideo>> related(
    String videoId, {
    String title = '',
    String author = '',
  }) async {
    final cached = _relatedCache[videoId];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < _relatedCacheTtl) {
      return cached.$2;
    }
    final authed = _authed;
    var list = await _firstNonEmpty([
      _guard('Music radio', () => _musicRadio(videoId)),
      if (authed != null)
        _guard('Related (signed in)', () => _relatedVia(authed, videoId)),
      _guard('Related', () => _relatedVia(_plain, videoId)),
      _guard('Mix', () => _mixVia(authed ?? _plain, videoId)),
    ]);
    if (list.isEmpty && title.isNotEmpty) {
      list = await _guard(
        'Similar search',
        () => _searchSimilar(videoId, title, author),
      );
    }
    if (list.isNotEmpty) _relatedCache[videoId] = (DateTime.now(), list);
    return list;
  }

  void invalidate(String videoId) {
    _cache.remove(videoId);
    _hdCache.remove(videoId);
    if (_preferred != null) _preferred = null;
  }
}
