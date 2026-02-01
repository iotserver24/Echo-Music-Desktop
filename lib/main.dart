import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get_it/get_it.dart';
import 'package:Echo/themes/theme.dart';
import 'package:Echo/ytmusic/modals/yt_config.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import 'generated/l10n.dart';
import 'services/download_manager.dart';
import 'services/file_storage.dart';
import 'services/library.dart';
import 'services/lyrics.dart';
import 'services/media_player.dart';
import 'services/settings_manager.dart';
import 'utils/router.dart';
import 'ytmusic/ytmusic.dart';
import 'services/yt_audio_stream.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Show a loading app while initializing
  runApp(const MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 20),
            Text('Loading Echo Music...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    ),
  ));

  try {
    await initialiseHive();

    // Initialize JustAudioBackground for notifications and background playback
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.echo.music.audio',
      androidNotificationChannelName: 'Echo Music',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
    );

    // Initialize JustAudioMediaKit for Windows, Linux, and macOS
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      // Prefer bundled libmpv (in lib/ next to executable or in usr/lib when in AppImage) so users don't need to install it
      String? bundledLibmpv;
      try {
        final exeFile = File(Platform.resolvedExecutable);
        final exeDir = exeFile.parent.path;
        final libDirs = [path.join(exeDir, 'lib'), path.join(exeFile.parent.parent.path, 'lib')];
        for (final libDir in libDirs) {
          for (final name in ['libmpv.so.2', 'libmpv.so.1', 'libmpv.so']) {
            final candidate = path.join(libDir, name);
            if (File(candidate).existsSync()) {
              bundledLibmpv = candidate;
              break;
            }
          }
          if (bundledLibmpv != null) break;
        }
      } catch (_) {}
      JustAudioMediaKit.ensureInitialized(libmpv: bundledLibmpv);
      JustAudioMediaKit.bufferSize = 8 * 1024 * 1024;
      JustAudioMediaKit.title = 'Echo Music';
      JustAudioMediaKit.prefetchPlaylist = true;
      JustAudioMediaKit.pitch = true;
    }

    String? visitorId = await Hive.box('SETTINGS').get('VISITOR_ID');

    YTMusic ytMusic = YTMusic(
      config:
          YTConfig(visitorData: visitorId ?? '', language: 'en', location: 'IN'),
      onIdUpdate: (visitorId) async {
        await Hive.box('SETTINGS').put('VISITOR_ID', visitorId);
      },
    );

    final GlobalKey<NavigatorState> panelKey = GlobalKey<NavigatorState>();

    await FileStorage.initialise();
    FileStorage fileStorage = FileStorage();
    SettingsManager settingsManager = SettingsManager();

    GetIt.I.registerSingleton<SettingsManager>(settingsManager);

    // Start Local Audio Server
    final String audioStreamUrl = await createAudioStreamServer();
    GetIt.I.registerSingleton<String>(audioStreamUrl,
        instanceName: 'audioStreamUrl');

    MediaPlayer mediaPlayer = MediaPlayer();
    GetIt.I.registerSingleton<MediaPlayer>(mediaPlayer);
    LibraryService libraryService = LibraryService();
    GetIt.I.registerSingleton<DownloadManager>(DownloadManager());
    GetIt.I.registerSingleton(panelKey);
    GetIt.I.registerSingleton<YTMusic>(ytMusic);

    GetIt.I.registerSingleton<FileStorage>(fileStorage);

    GetIt.I.registerSingleton<LibraryService>(libraryService);
    GetIt.I.registerSingleton<LyricsService>(LyricsService());

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => settingsManager),
          ChangeNotifierProvider(create: (_) => mediaPlayer),
          ChangeNotifierProvider(create: (_) => libraryService),
        ],
        child: const Echo(),
      ),
    );
  } catch (e, stackTrace) {
    debugPrint('Initialization error: $e');
    debugPrint('Stack trace: $stackTrace');
    final String errStr = e.toString();
    final bool isLibmpv = errStr.contains('libmpv') && Platform.isLinux;
    final bool isLockError = errStr.contains('lock failed') ||
        (e is FileSystemException && e.osError?.errorCode == 11);
    runApp(MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error, color: Colors.red, size: 50),
                  const SizedBox(height: 20),
                  const Text('Failed to start Echo Music',
                      style: TextStyle(color: Colors.white, fontSize: 18)),
                  const SizedBox(height: 10),
                  Text(errStr,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center),
                  if (isLibmpv) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Install libmpv:',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Fedora: sudo dnf install mpv-libs\n'
                      'Debian/Ubuntu: sudo apt install libmpv-dev',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (isLockError) ...[
                    const SizedBox(height: 16),
                    const Text(
                      'Another instance may be running. Close it and try again.',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'If the problem persists:\n'
                      'rm -f ~/.local/share/com.echo.music/database/*.lock',
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ));
  }
}

class Echo extends StatelessWidget {
  const Echo({super.key});
  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      child: MaterialApp.router(
        title: 'Echo Music',
        routerConfig: router,
        locale: Locale(context.watch<SettingsManager>().language['value']!),
        localizationsDelegates: const [
          S.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: S.delegate.supportedLocales,
        debugShowCheckedModeBanner: false,
        themeMode: context.watch<SettingsManager>().themeMode,
        theme: AppTheme.light(
          primary: Colors.black,
        ),
        darkTheme: AppTheme.dark(
          primary: Colors.white,
        ),
      ),
    );
  }
}

Future<void> initialiseHive() async {
  String? applicationDataDirectoryPath;
  if (Platform.isWindows || Platform.isLinux) {
    applicationDataDirectoryPath =
        "${(await getApplicationSupportDirectory()).path}/database";
  }
  await Hive.initFlutter(applicationDataDirectoryPath);
  const int maxLockRetries = 3;
  const Duration lockRetryDelay = Duration(milliseconds: 800);
  final boxNames = ['SETTINGS', 'LIBRARY', 'SEARCH_HISTORY', 'SONG_HISTORY', 'FAVOURITES', 'DOWNLOADS'];
    for (final name in boxNames) {
    int attempt = 0;
    while (true) {
      try {
        await Hive.openBox(name);
        break;
      } catch (e) {
        final isLockError = (e is FileSystemException &&
                (e.osError?.errorCode == 11 || e.message.contains('lock'))) ||
            e.toString().contains('lock failed');
        if (isLockError && attempt < maxLockRetries) {
          attempt++;
          await Future<void>.delayed(lockRetryDelay);
          continue;
        }
        rethrow;
      }
    }
  }
}
