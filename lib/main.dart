// Nevermore IPTV: live TV on Google TV from an Xtream Codes login or an M3U link. Design: docs\Design.md.
//
// Start: read this TV's sources and lists, take a source handed in by tools\install.ps1 (if any), then open the TV, or
// Add a source when there is none yet. The install script's -PlaybackTest opens the playback test instead.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'core/library.dart';
import 'core/presets.dart';
import 'core/setup_channel.dart';
import 'core/vpn.dart';
import 'playback_test.dart';
import 'ui/add_source_page.dart';
import 'ui/tv.dart';
import 'ui/watch_page.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // the whole screen: no status or navigation bar over the video (a TV has none; a phone hides them)
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  runApp(const NevermoreApp());
}

class NevermoreApp extends StatelessWidget {
  const NevermoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nevermore IPTV',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: tvAccent, scaffoldBackgroundColor: tvBackground),
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      home: const StartPage(),
    );
  }
}

void openTv({String? notice}) => navigatorKey.currentState!.pushAndRemoveUntil(
  MaterialPageRoute(builder: (_) => WatchPage(notice: notice)),
  (_) => false,
);

/// What the install script handed in, applied: a source, a WireGuard file, a preset code. Returns the line for the
/// TV's notice (no login in it), or null when there was nothing.
Future<String?> applySetup(Map<Object?, Object?>? setup) async {
  if (setup == null) return null;
  final done = <String>[];
  if (setup['kind'] == 'xtream' || setup['kind'] == 'm3u') {
    final source = await library.applySetup(setup);
    if (source != null) done.add(source.name);
  }
  // VPN settings from tools\install.ps1 -VpnConfig (base64, so the file's lines survive the shell)
  final vpnText = setup['vpn_conf_b64'];
  if (vpnText is String && vpnText.isNotEmpty) {
    try {
      if (await vpn.save('${setup['vpn_name'] ?? ''}', utf8.decode(base64.decode(vpnText)))) {
        done.add('VPN file ${vpn.settings?.name ?? ''}');
      }
    } on FormatException {
      // not base64: ignored, the VPN card says there are no settings
    }
  }
  final code = setup['preset'];
  if (code is String && code.trim().isNotEmpty) {
    // once the list is read (the TV opens meanwhile), with its own line on the screen
    unawaited(
      applyPresetCode(library, code).then((line) {
        setupNotices.value = null;
        setupNotices.value = 'Install script: $line';
      }),
    );
  }
  return done.isEmpty ? null : 'Set up from the install script: ${done.join(', ')}';
}

class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  String? _problem;

  @override
  void initState() {
    super.initState();
    listenForSetups((setup) async {
      final notice = await applySetup(setup);
      setupNotices.value = null;
      setupNotices.value = notice;
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      await library.load();
    } catch (err) {
      // a failing read of the encrypted store or a broken file: a message and a way out, not a spinner for good
      if (mounted) setState(() => _problem = 'This TV\'s settings could not be read.\n$err');
      return;
    }
    try {
      await vpn.load();
    } catch (_) {
      // a broken VPN record must not keep the TV from opening; the VPN card says there are no settings
    }
    final setup = await takeSetup();
    final notice = await applySetup(setup);
    // the lists are read after a login handed in at start is saved, so the first read uses it
    library.startRefreshing();
    final nav = navigatorKey.currentState!;
    if (setup?['autorun'] == true) {
      await nav.pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlaybackTestPage(
            xtream: library.firstXtreamClient(),
            autorun: true,
            platformView: setup?['view'] == 'platform',
          ),
        ),
      );
    } else if (library.sources.isEmpty) {
      await nav.pushReplacement(
        MaterialPageRoute(builder: (_) => const AddSourcePage(firstRun: true, onFinished: openTv)),
      );
    } else {
      openTv(notice: notice);
    }
  }

  /// Everything this TV kept, gone: the logins and the VPN file from the encrypted store, the lists and choices from
  /// the app's folder. Then the start again, which opens Add a source.
  Future<void> _startAfresh() async {
    setState(() => _problem = null);
    try {
      await const FlutterSecureStorage().deleteAll();
      final folder = await getApplicationSupportDirectory();
      await for (final f in folder.list()) {
        if (f is File) await f.delete();
      }
    } catch (_) {
      // whatever could be cleared is cleared
    }
    await _start();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final problem = _problem;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: overscanOf(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/brand/mark.png', width: 128, height: 128),
              const SizedBox(height: 12),
              Text('Nevermore IPTV', style: text.headlineMedium),
              const SizedBox(height: 16),
              if (problem == null)
                const CircularProgressIndicator()
              else ...[
                Text(
                  problem,
                  style: text.bodyMedium?.copyWith(color: tvAlert),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    TvButton(
                      label: 'Try again',
                      autofocus: true,
                      onPressed: () {
                        setState(() => _problem = null);
                        unawaited(_start());
                      },
                    ),
                    TvButton(
                      label: 'Start afresh (logins and choices removed)',
                      onPressed: () => unawaited(_startAfresh()),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
