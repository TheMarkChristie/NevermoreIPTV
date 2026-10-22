// Step 1 of the design: a playback test on a real Google TV. It plays a few channels one at a time and records what
// each did - time to the first picture, stalls, picture size, the player's own error text - and, for the provider's
// channels, the connections in use before, during and after. Results go to the TV's log as "NVTEST ..." lines, which
// tools\install.ps1 -PlaybackTest reads back over adb; the script opens this screen instead of the TV screens.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import 'core/setup_channel.dart';
import 'core/xtream.dart';

const _playFor = Duration(seconds: 30);
const _providerGroup = 'UNITED KINGDOM';
const _providerChannel = 'UK: BBC ONE SCOTLAND';

class TestChannel {
  const TestChannel(this.name, {this.url, this.output});

  final String name;
  final String? url;

  /// m3u8 or ts for one of the provider's channels; null for a Free-TV address.
  final String? output;

  bool get provider => output != null;
  bool get hls => output == 'm3u8' || (url?.contains('.m3u8') ?? false);
}

const _tests = <TestChannel>[
  TestChannel('BBC One Scotland - provider, HLS', output: 'm3u8'),
  TestChannel('BBC One Scotland - provider, TS', output: 'ts'),
  TestChannel('NRK1 - encrypted, Norway only', url: 'https://nrk-live-no.akamaized.net/nrk1/muxed.m3u8'),
  TestChannel('Frikanalen - fMP4', url: 'https://frikanalen.no/stream/index.m3u8'),
  TestChannel('Today FM - Irish radio, AAC', url: 'https://live-bauerie.sharp-stream.com/TDAAC'),
];

class PlaybackTestPage extends StatefulWidget {
  const PlaybackTestPage({super.key, this.xtream, this.autorun = false, this.platformView = false});

  /// The first provider login on this TV, if any.
  final XtreamClient? xtream;
  final bool autorun;
  final bool platformView;

  @override
  State<PlaybackTestPage> createState() => _PlaybackTestPageState();
}

class _PlaybackTestPageState extends State<PlaybackTestPage> {
  XtreamClient? _xtream;
  String? _streamId;
  VideoPlayerController? _player;
  VideoViewType _view = VideoViewType.textureView;
  bool _running = false;
  int _run = 0;
  String _status = 'Starting';
  final List<String> _lines = [];
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // Leaving the screen stops playback at once, so a TV in standby never holds one of the provider's connections.
    _life = AppLifecycleListener(onHide: _stop, onPause: _stop);
    _init();
  }

  @override
  void dispose() {
    _life.dispose();
    _stop();
    super.dispose();
  }

  void _say(String line) {
    // ignore: avoid_print
    print('NVTEST $line');
    if (!mounted) return;
    setState(() {
      _lines.insert(0, line);
      if (_lines.length > 12) _lines.removeLast();
    });
  }

  Future<void> _init() async {
    try {
      final device = await setupChannel.invokeMethod<Map<Object?, Object?>>('device');
      if (device != null) {
        _say(
          'device ${device['maker']} ${device['model']}, Android ${device['android']} (SDK ${device['sdk']}), '
          'ABIs ${device['abis']}',
        );
      }
    } on PlatformException catch (err) {
      _say('setup channel failed: ${err.message}');
    }
    _xtream = widget.xtream;
    _say(_xtream == null ? 'no provider login on this TV: the provider tests will be skipped' : 'provider login found');
    if (widget.platformView) _view = VideoViewType.platformView;
    setState(() => _status = 'Ready');
    if (widget.autorun) unawaited(_runAll());
  }

  String _scrub(String text) => _xtream?.scrub(text) ?? text;

  String get _viewName => _view == VideoViewType.platformView ? 'platform view' : 'texture';

  Future<void> _stop() async {
    _run++;
    final player = _player;
    if (player == null) return;
    if (mounted) setState(() => _player = null);
    await player.pause();
    await player.dispose();
  }

  Future<void> _runAll() async {
    if (_running) return;
    _running = true;
    final run = ++_run;
    _say('run all, view $_viewName, ${_playFor.inSeconds} s each');
    for (final test in _tests) {
      if (run != _run) break;
      await _runOne(test, run);
    }
    _running = false;
    _say(run == _run ? 'done' : 'stopped');
    if (mounted) setState(() => _status = run == _run ? 'Done' : 'Stopped');
  }

  Future<void> _runSingle(TestChannel test) async {
    if (_running) return;
    _running = true;
    final run = ++_run;
    await _runOne(test, run);
    _running = false;
    if (mounted) setState(() => _status = 'Ready');
  }

  Future<String?> _findProviderStream() async {
    if (_streamId != null) return _streamId;
    final xtream = _xtream!;
    final groups = await xtream.liveCategories();
    final group = groups.where((g) => '${g['category_name']}'.trim().toUpperCase() == _providerGroup).firstOrNull;
    final streams = await xtream.liveStreams(categoryId: group == null ? null : '${group['category_id']}');
    final stream = streams.where((s) => '${s['name']}'.trim().toUpperCase() == _providerChannel).firstOrNull;
    return _streamId = stream == null ? null : '${stream['stream_id']}';
  }

  Future<void> _runOne(TestChannel test, int run) async {
    setState(() => _status = 'Playing: ${test.name}');
    final result = <String, String>{'test': test.name, 'view': _viewName};
    void report() => _say('result | ${result.entries.map((e) => '${e.key}=${e.value}').join(' | ')}');

    var url = test.url;
    int? before;
    if (test.provider) {
      final xtream = _xtream;
      if (xtream == null) {
        result['skipped'] = 'no provider login';
        return report();
      }
      try {
        final account = await xtream.account();
        before = account.active;
        result['in use before'] = '${account.active} of ${account.max}';
        if (account.active >= account.max) {
          result['skipped'] = 'both connections are in use';
          return report();
        }
        final id = await _findProviderStream();
        if (id == null) {
          result['skipped'] = '$_providerChannel not found in $_providerGroup';
          return report();
        }
        url = xtream.streamUrl(id, test.output!);
      } on XtreamError catch (err) {
        result['skipped'] = 'provider: $err';
        return report();
      }
    }
    if (run != _run) return;

    final player = VideoPlayerController.networkUrl(
      Uri.parse(url!),
      formatHint: test.hls ? VideoFormat.hls : null,
      httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
      viewType: _view,
    );
    final clock = Stopwatch()..start();
    int? firstPicture;
    var stalls = 0;
    var wasBuffering = false;
    Duration? lastPosition;
    String? error;
    void watch() {
      final v = player.value;
      if (v.hasError) error ??= _scrub(v.errorDescription ?? 'unknown error');
      // Live positions do not start at zero, so the first picture is the first time the position moves.
      if (firstPicture == null && v.isPlaying && lastPosition != null && v.position > lastPosition!) {
        firstPicture = clock.elapsedMilliseconds;
      }
      if (v.isInitialized) lastPosition = v.position;
      if (firstPicture != null && v.isBuffering && !wasBuffering) stalls++;
      wasBuffering = v.isBuffering;
    }

    player.addListener(watch);
    setState(() => _player = player);
    try {
      await player.initialize().timeout(const Duration(seconds: 25));
      await player.play();
    } catch (err) {
      error ??= _scrub('$err');
    }

    final end = DateTime.now().add(_playFor);
    var askedDuring = false;
    while (run == _run && error == null && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (test.provider && !askedDuring && clock.elapsed > const Duration(seconds: 15)) {
        askedDuring = true;
        try {
          final account = await _xtream!.account();
          result['in use while playing'] = '${account.active} of ${account.max}';
        } on XtreamError catch (err) {
          result['in use while playing'] = 'unknown ($err)';
        }
      }
    }
    final size = player.value.size;
    player.removeListener(watch);
    if (_player == player) {
      setState(() => _player = null);
      await player.pause();
      await player.dispose();
    }

    result['played'] = firstPicture != null ? 'yes' : 'no';
    if (firstPicture != null) result['first picture'] = '${(firstPicture! / 1000).toStringAsFixed(1)} s';
    result['stalls'] = '$stalls';
    if (size.width > 0) result['size'] = '${size.width.toInt()}x${size.height.toInt()}';
    if (error != null) result['error'] = error!;

    // How long the provider keeps counting a channel after it stops: decides whether changing channel quickly can be
    // refused on a two-connection login.
    if (test.provider && before != null) {
      final stopped = DateTime.now();
      String freed = 'still counted after 60 s';
      for (var i = 0; i < 12 && run == _run; i++) {
        await Future<void>.delayed(const Duration(seconds: 5));
        try {
          if ((await _xtream!.account()).active <= before) {
            freed = '${DateTime.now().difference(stopped).inSeconds} s';
            break;
          }
        } on XtreamError catch (err) {
          freed = 'unknown ($err)';
          break;
        }
      }
      result['connection freed after'] = freed;
    }
    report();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final player = _player;
    return Scaffold(
      backgroundColor: const Color(0xFF101114),
      body: Padding(
        // Nothing in the outer 5% of the screen: TVs can crop it (overscan).
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 27),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 300,
              child: ListView(
                children: [
                  Text('Nevermore IPTV', style: text.titleLarge),
                  Text('Playback test', style: text.bodySmall),
                  const SizedBox(height: 12),
                  _TvButton(label: 'Run all', autofocus: true, onPressed: _runAll),
                  for (final test in _tests) _TvButton(label: test.name, onPressed: () => _runSingle(test)),
                  _TvButton(
                    label: 'View: $_viewName',
                    onPressed: () => setState(
                      () => _view = _view == VideoViewType.textureView
                          ? VideoViewType.platformView
                          : VideoViewType.textureView,
                    ),
                  ),
                  _TvButton(label: 'Stop', onPressed: _stop),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: ColoredBox(
                      color: Colors.black,
                      child: player == null
                          ? const Center(child: Text('No video'))
                          : ValueListenableBuilder<VideoPlayerValue>(
                              valueListenable: player,
                              builder: (context, value, _) => Center(
                                child: AspectRatio(
                                  aspectRatio: value.isInitialized && value.aspectRatio > 0
                                      ? value.aspectRatio
                                      : 16 / 9,
                                  child: VideoPlayer(player),
                                ),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(_status, style: text.titleSmall),
                  const SizedBox(height: 4),
                  Expanded(
                    child: ListView(children: [for (final line in _lines) Text(line, style: text.bodySmall)]),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A button that shows clearly where the remote's focus is.
class _TvButton extends StatelessWidget {
  const _TvButton({required this.label, required this.onPressed, this.autofocus = false});

  final String label;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: OutlinedButton(
        autofocus: autofocus,
        onPressed: onPressed,
        style: ButtonStyle(
          alignment: Alignment.centerLeft,
          padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? Colors.black : Colors.white,
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? Colors.white : Colors.transparent,
          ),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(color: s.contains(WidgetState.focused) ? Colors.white : Colors.white24, width: 2),
          ),
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
          ),
        ),
        child: Text(label),
      ),
    );
  }
}
