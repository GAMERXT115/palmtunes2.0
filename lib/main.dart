import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_handler.dart';
import 'auth_store.dart';
import 'bass_meter.dart';
import 'biometric_lock.dart';
import 'cloud_sync.dart';
import 'downloads.dart';
import 'firebase_options.dart';
import 'gesture_bridge.dart';
import 'list.dart';
import 'login_screen.dart';
import 'mini_bar.dart';
import 'player_hub.dart';
import 'search.dart';
import 'settings.dart';
import 'splash_screen.dart';
import 'ui.dart';
import 'yt_streams.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ),
  );

  // The saved accent colour is read on its own (it is quick) so the splash
  // already matches the user's theme while everything else loads.
  var accent = const Color(0xFFE11D48);
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('pt_accent');
    if (saved != null) accent = Color(saved);
  } catch (_) {}

  runApp(
    ColoredBox(
      color: AppColors.background,
      child: SplashLauncher(accent: accent, boot: _boot),
    ),
  );
}

/// Everything that has to load before the app can show. It runs behind the
/// splash screen and returns the app to fade into.
Future<Widget> _boot() async {
  // Firebase starts first: it is only local setup, no internet is needed.
  var firebaseOk = true;
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    firebaseOk = false;
    debugPrint('[PalmTunes] Firebase could not start -> $e');
  }

  // Music category: keeps playing in the background and ducks for calls.
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  final settings = SettingsStore();
  final songs = SongListStore();
  final downloads = DownloadsStore();
  final auth = AuthStore(firebaseOk: firebaseOk);
  await Future.wait([
    settings.load(),
    songs.load(),
    downloads.load(),
    auth.load(),
  ]);

  // Face ID for opening the app (only for signed-in accounts).
  final biometric = BiometricLock();
  await biometric.load(auth);

  // Keeps downloads and cloud saves in sync (queues while offline).
  final cloud = CloudSyncStore(auth, downloads);
  await cloud.attach();
  // The song list is kept in sync with the cloud too (queues while offline).
  await songs.attach(auth);

  await loadYoutubeAuth();
  downloads.resumeQueue();

  final hub = PlayerHub(settings: settings, downloads: downloads);
  await hub.initDeviceVolume();
  final meter = BassMeter(hub);
  final gestures = GestureBridge(hub);
  await gestures.load();
  // The camera stays off on the login and sign-up screens.
  void syncCamera() =>
      unawaited(gestures.setSuspended(!auth.inApp || biometric.locked));
  auth.addListener(syncCamera);
  biometric.addListener(syncCamera);
  syncCamera();

  try {
    await AudioService.init(
      builder: () => HubAudioHandler(hub),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.palmtunes.app.playback',
        androidNotificationChannelName: 'Palm Tunes playback',
        androidNotificationOngoing: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
    );
  } catch (e) {
    debugPrint('[PalmTunes] Lock-screen controls unavailable -> $e');
  }

  return MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsStore>.value(value: settings),
      ChangeNotifierProvider<SongListStore>.value(value: songs),
      ChangeNotifierProvider<DownloadsStore>.value(value: downloads),
      ChangeNotifierProvider<AuthStore>.value(value: auth),
      ChangeNotifierProvider<CloudSyncStore>.value(value: cloud),
      ChangeNotifierProvider<BiometricLock>.value(value: biometric),
      ChangeNotifierProvider<NavController>(create: (_) => NavController()),
      ChangeNotifierProvider<PlayerHub>.value(value: hub),
      Provider<BassMeter>.value(value: meter),
      ChangeNotifierProvider<GestureBridge>.value(value: gestures),
    ],
    child: const PalmTunesApp(),
  );
}

/// Loads the YouTube sign-in cookie line, if there is one: first from the
/// app's own storage folder, then from the cookies.txt bundled as an asset.
Future<void> loadYoutubeAuth() async {
  try {
    final support = await getApplicationSupportDirectory();
    final file = File(p.join(support.path, 'cookies.txt'));
    if (await file.exists()) {
      final raw = (await file.readAsString()).trim();
      if (raw.isNotEmpty) {
        YtStreams.instance.setCookies(raw);
        debugPrint('[PalmTunes] Loaded cookies from app storage');
        return;
      }
    }
  } catch (_) {}
  try {
    final raw = (await rootBundle.loadString('cookies.txt'))
        .split('\n')
        .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#'))
        .join('\n')
        .trim();
    if (raw.isNotEmpty) {
      YtStreams.instance.setCookies(raw);
      debugPrint('[PalmTunes] Loaded cookies from bundled asset');
      return;
    }
  } catch (_) {}
  debugPrint(
    '[PalmTunes] No cookies.txt found (bundled asset or app storage).',
  );
}

class PalmTunesApp extends StatelessWidget {
  const PalmTunesApp({super.key});

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    final accent = context.select<SettingsStore, Color>((s) => s.accentColor);
    return MaterialApp(
      title: 'Palm Tunes',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(accent),
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          child ?? const SizedBox.shrink(),
          const CameraPreviewHost(),
          const NotchHost(),
        ],
      ),
      home: const AuthGate(child: AppShell()),
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  static const double navBarHeight = 64;

  static const List<_NavItem> _items = [
    _NavItem(Icons.queue_music_rounded, 'List'),
    _NavItem(Icons.search_rounded, 'Search'),
    _NavItem(Icons.download_rounded, 'Downloads'),
    _NavItem(Icons.settings_rounded, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavController>();
    final showMini = context.select<PlayerHub, bool>(
      (h) => h.current != null && !h.isPlayerOpen,
    );
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return PopScope(
      canPop: nav.index == NavController.listTab,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) nav.setIndex(NavController.listTab);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            const Positioned.fill(child: _Backdrop()),
            SafeArea(
              bottom: false,
              child: IndexedStack(
                index: nav.index,
                children: const [
                  ListScreen(),
                  SearchScreen(),
                  DownloadsScreen(),
                  SettingsScreen(),
                ],
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: bottomInset + navBarHeight + 18,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, anim) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.4),
                    end: Offset.zero,
                  ).animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: showMini
                    ? const MiniBar(key: ValueKey('mini'))
                    : const SizedBox.shrink(key: ValueKey('no-mini')),
              ),
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: bottomInset + 8,
              child: _GlassNavBar(
                items: _items,
                selected: nav.index,
                onTap: nav.setIndex,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem(this.icon, this.label);
}

class _GlassNavBar extends StatelessWidget {
  final List<_NavItem> items;
  final int selected;
  final ValueChanged<int> onTap;

  const _GlassNavBar({
    required this.items,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return GlassContainer(
      borderRadius: 24,
      opacity: 0.12,
      padding: const EdgeInsets.all(6),
      height: AppShell.navBarHeight,
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: i == selected
                        ? accent.withValues(alpha: 0.2)
                        : Colors.transparent,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        items[i].icon,
                        size: 23,
                        color: i == selected ? accent : Colors.white54,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        items[i].label,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: i == selected ? accent : Colors.white54,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0A0A0D), Color(0xFF150A0D), Color(0xFF0A0A0D)],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            top: -140,
            left: -110,
            child: _Glow(color: accent.withValues(alpha: 0.30), size: 360),
          ),
          Positioned(
            bottom: -160,
            right: -120,
            child: _Glow(color: accent.withValues(alpha: 0.22), size: 420),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  final Color color;
  final double size;
  const _Glow({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
  }
}
