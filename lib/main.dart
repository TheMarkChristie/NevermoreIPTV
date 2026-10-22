// Nevermore IPTV: live TV on Google TV from an Xtream Codes login or an M3U link. Design: docs\Design.md.
//
// Start: read this TV's sources and lists, take a source handed in by tools\install.ps1 (if any), then open the TV, or
// Add a source when there is none yet. The install script's -PlaybackTest opens the playback test instead.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/library.dart';
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

void openTv() =>
    navigatorKey.currentState!.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const WatchPage()), (_) => false);

class StartPage extends StatefulWidget {
  const StartPage({super.key});

  @override
  State<StartPage> createState() => _StartPageState();
}

class _StartPageState extends State<StartPage> {
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    await library.load();
    await vpn.load();
    final setup = await takeSetup();
    if (setup != null && (setup['kind'] == 'xtream' || setup['kind'] == 'm3u')) {
      await library.applySetup(setup);
    }
    // VPN settings from tools\install.ps1 -VpnConfig (base64, so the file's lines survive the shell)
    final vpnText = setup?['vpn_conf_b64'];
    if (vpnText is String && vpnText.isNotEmpty) {
      try {
        await vpn.save('${setup?['vpn_name'] ?? ''}', utf8.decode(base64.decode(vpnText)));
      } on FormatException {
        // not base64: ignored, the VPN card says there are no settings
      }
    }
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
      openTv();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset('assets/brand/mark.png', width: 128, height: 128),
            const SizedBox(height: 12),
            Text('Nevermore IPTV', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 16),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
