/// Watching: the video fills the screen. Up / Down (and channel and media keys, or a swipe) change channel within the
/// category; OK (or a tap) brings up the guide over the video, where the category is changed and shows are searched
/// for; Back closes the guide, and twice on the bare video leaves the app.
///
/// One stream per TV: the old channel is stopped before the next starts, a channel only starts once the remote has been
/// still for a moment (browsing never opens extra connections), and leaving the screen stops playback.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/library.dart';
import '../core/model.dart';
import '../core/show_search.dart';
import '../core/vpn.dart';
import 'guide_view.dart';
import 'manage_channels_page.dart';
import 'settings_page.dart';
import 'tv.dart';

const _startTimeout = Duration(seconds: 10);
const _zapSettle = Duration(milliseconds: 600);

class WatchPage extends StatefulWidget {
  const WatchPage({super.key});

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  final _videoFocus = FocusNode(debugLabel: 'video');
  VideoPlayerController? _player;
  PlayableChannel? _current;
  int _token = 0;
  bool _starting = false;
  (String, String)? _error;

  List<Category> _categories = [];
  List<PlayableChannel> _all = [];

  /// The category up / down moves through; null: All.
  String? _zapCategory;
  bool _guideOpen = false;

  bool _info = false;
  Timer? _infoTimer;
  Timer? _zapTimer;
  DateTime? _lastBack;
  bool _backHint = false;
  Timer? _backTimer;
  bool _away = false;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    library.addListener(_onLibrary);
    vpn.addListener(_onVpn);
    _vpnWasOn = vpn.state == VpnState.on;
    _onLibrary();
    _life = AppLifecycleListener(onHide: _onHide, onShow: _onShow);
    unawaited(_startLast());
  }

  @override
  void dispose() {
    library.removeListener(_onLibrary);
    vpn.removeListener(_onVpn);
    _life.dispose();
    _infoTimer?.cancel();
    _zapTimer?.cancel();
    _backTimer?.cancel();
    _videoFocus.dispose();
    unawaited(_stopPlayer());
    super.dispose();
  }

  bool _vpnWasOn = false;

  /// The VPN went on or off: the stream is opened again by the new route (the old one goes with the old address).
  void _onVpn() {
    final on = vpn.state == VpnState.on;
    if (on == _vpnWasOn) return;
    _vpnWasOn = on;
    final ch = _current;
    if (ch != null && !_away && mounted) unawaited(_play(ch));
  }

  void _onLibrary() {
    final categories = library.categories();
    final seen = <String>{};
    final all = [
      for (final c in categories)
        for (final ch in c.channels)
          if (seen.add(ch.uid)) ch,
    ];
    if (!mounted) return;
    setState(() {
      _categories = categories;
      _all = all;
      // the playing channel's entry, renamed or moved
      final uid = _current?.uid;
      if (uid != null) _current = all.where((c) => c.uid == uid).firstOrNull ?? _current;
    });
    // the first channels arrived (a list read for the first time): start watching
    if (_current == null && _all.isNotEmpty && !_away) unawaited(_startLast());
  }

  /// The first start's other candidates, tried in turn while each fails; null once one plays or the remote is used.
  List<PlayableChannel>? _autoStart;

  Future<void> _startLast() async {
    if (_all.isEmpty || _current != null) return;
    final last = _all.where((c) => c.uid == library.lastChannel).firstOrNull;
    if (last != null) {
      await _play(last);
      return;
    }
    // the first start: channels that play anywhere (not Free-TV's Ⓖ ones for one country), tried until one plays,
    // so a new TV never opens on an error
    final candidates = _all.where((c) => !c.geoBlocked).take(6).toList();
    if (candidates.isEmpty) candidates.add(_all.first);
    _autoStart = candidates.sublist(1);
    await _play(candidates.first, quick: true);
  }

  void _onHide() {
    _away = true;
    _token++;
    unawaited(_stopPlayer());
  }

  void _onShow() {
    if (!_away) return;
    _away = false;
    final ch = _current;
    if (ch != null && ModalRoute.of(context)?.isCurrent == true) unawaited(_play(ch));
  }

  // ---- playing ----

  Future<void> _stopPlayer() async {
    final p = _player;
    _player = null;
    if (p == null) return;
    p.removeListener(_onPlayerValue);
    await p.pause();
    await p.dispose();
  }

  void _onPlayerValue() {
    final p = _player;
    final ch = _current;
    if (p == null || ch == null || !p.value.hasError || _starting) return;
    // the stream dropped while watching: start it again (with the usual retries)
    unawaited(_play(ch, attempt: 1, error: p.value.errorDescription));
  }

  /// [quick]: no retries (the first start moves on to its next candidate instead).
  Future<void> _play(PlayableChannel ch, {int attempt = 0, String? error, bool quick = false}) async {
    final token = ++_token;
    _zapTimer?.cancel();
    await _stopPlayer();
    if (!mounted || token != _token) return;
    setState(() {
      _current = ch;
      _starting = true;
      _error = null;
    });
    if (attempt == 0) _showInfo();
    String failure = error ?? '';
    try {
      final address = await library.streamFor(ch);
      if (token != _token) return;
      // drawn by an Android SurfaceView, not a Flutter texture: on a real Google TV (22 Oct 2026) the texture showed
      // the picture in one corner with the rest of the screen green
      final player = VideoPlayerController.networkUrl(
        Uri.parse(address.url),
        formatHint: address.hls ? VideoFormat.hls : null,
        httpHeaders: address.headers,
        viewType: VideoViewType.platformView,
      );
      _player = player;
      await player.initialize().timeout(_startTimeout);
      if (token != _token) return;
      await player.play();
      player.addListener(_onPlayerValue);
      if (mounted) setState(() => _starting = false);
      _autoStart = null;
      // remembered without holding up (or failing) the channel that is playing
      unawaited(library.setLastChannel(ch.uid).catchError((_) {}));
      return;
    } catch (err) {
      failure = '$err';
    }
    if (token != _token) return;
    await _stopPlayer();
    final more = _autoStart;
    if (quick && more != null && more.isNotEmpty) {
      if (mounted) await _play(more.removeAt(0), quick: true);
      return;
    }
    _autoStart = null;
    if (!quick && attempt < 2) {
      await Future<void>.delayed(Duration(milliseconds: attempt == 0 ? 1500 : 3000));
      if (token == _token && mounted) await _play(ch, attempt: attempt + 1, error: failure);
      return;
    }
    final why = await library.explainFailure(ch, failure);
    if (token != _token || !mounted) return;
    setState(() {
      _starting = false;
      _error = why;
    });
  }

  List<PlayableChannel> get _zapList {
    final name = _zapCategory;
    if (name == null) return _all;
    return _categories.where((c) => c.name == name).firstOrNull?.channels ?? _all;
  }

  /// Next / previous channel: shown at once, played once the remote is still.
  void _step(int delta) {
    final list = _zapList;
    if (list.isEmpty) return;
    _autoStart = null;
    final at = list.indexWhere((c) => c.uid == _current?.uid);
    final next = list[((at < 0 ? 0 : at) + delta) % list.length];
    _token++;
    unawaited(_stopPlayer());
    setState(() {
      _current = next;
      _starting = true;
      _error = null;
    });
    _showInfo();
    _zapTimer?.cancel();
    _zapTimer = Timer(_zapSettle, () => _play(next));
  }

  void _showInfo() {
    _infoTimer?.cancel();
    setState(() => _info = true);
    _infoTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _info = false);
    });
  }

  // ---- the guide, Settings, Manage channels ----

  void _openGuide() {
    if (_all.isEmpty) {
      unawaited(_openSettings());
      return;
    }
    setState(() {
      _guideOpen = true;
      _info = false;
    });
  }

  void _closeGuide() {
    setState(() => _guideOpen = false);
    _videoFocus.requestFocus();
  }

  int get _guideCategory {
    final name = _zapCategory;
    if (name == null) return 0;
    final i = _categories.indexWhere((c) => c.name == name);
    return i < 0 ? 0 : i + 1;
  }

  /// Stops playback (one connection: nothing plays behind other screens), opens [page], and on return plays on.
  Future<void> _leaveFor(Widget page) async {
    _token++;
    _away = true;
    await _stopPlayer();
    if (!mounted) return;
    setState(() => _guideOpen = false);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    _away = false;
    if (!mounted) return;
    _videoFocus.requestFocus();
    final ch = _current;
    final still = ch == null ? null : _all.where((c) => c.uid == ch.uid).firstOrNull;
    if (still != null) {
      await _play(still);
    } else {
      _current = null;
      await _startLast();
    }
  }

  Future<void> _openSettings() => _leaveFor(const SettingsPage());

  Future<void> _openManage(PlayableChannel ch) =>
      _leaveFor(ManageChannelsPage(sourceId: ch.source.id, groupId: ch.channel.group));

  // ---- keys ----

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (_guideOpen) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.channelUp ||
        k == LogicalKeyboardKey.pageUp ||
        k == LogicalKeyboardKey.mediaTrackPrevious) {
      _step(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.channelDown ||
        k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.mediaTrackNext) {
      _step(1);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.numpadEnter ||
            k == LogicalKeyboardKey.gameButtonA ||
            k == LogicalKeyboardKey.guide ||
            k == LogicalKeyboardKey.info)) {
      _openGuide();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onBack() {
    if (_guideOpen) {
      _closeGuide();
      return;
    }
    final now = DateTime.now();
    if (_lastBack != null && now.difference(_lastBack!) < const Duration(seconds: 2)) {
      unawaited(_stopPlayer());
      // leaving the app takes the VPN down too: nothing else on the TV uses it
      unawaited(vpn.turnOff().whenComplete(SystemNavigator.pop));
      return;
    }
    _lastBack = now;
    _backTimer?.cancel();
    setState(() => _backHint = true);
    _backTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _backHint = false);
    });
  }

  // ---- drawing ----

  Widget _video(TextTheme text, {bool small = false}) {
    final player = _player;
    if (player == null) {
      return _starting ? const Center(child: CircularProgressIndicator()) : const SizedBox.expand();
    }
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, v, _) {
        if (!v.isInitialized) return const Center(child: CircularProgressIndicator());
        if (v.size.width == 0) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.radio, size: small ? 32 : 64, color: tvMuted),
                if (!small) ...[const SizedBox(height: 8), Text(_current?.name ?? '', style: text.titleLarge)],
              ],
            ),
          );
        }
        return Center(
          child: AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(player)),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _videoFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!_guideOpen)
                GestureDetector(
                  onTap: _openGuide,
                  // on a touch screen: swipe up for the next channel, down for the previous
                  onVerticalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -300) _step(1);
                    if (v > 300) _step(-1);
                  },
                  child: _video(text),
                ),
              if (_all.isEmpty && !_guideOpen) _empty(text),
              if (_error != null && !_guideOpen) _errorCard(text),
              if (_info && !_guideOpen && _current != null) _infoBar(text),
              if (_guideOpen)
                GuideView(
                  categories: _categories,
                  all: _all,
                  category: _guideCategory,
                  playing: _current,
                  video: _video(text, small: true),
                  onPlay: (ch, category) {
                    _autoStart = null;
                    _zapCategory = category;
                    _closeGuide();
                    unawaited(_play(ch));
                  },
                  onClose: _closeGuide,
                  onSettings: () => unawaited(_openSettings()),
                  onManage: (ch) => unawaited(_openManage(ch)),
                ),
              if (_backHint)
                Positioned(
                  bottom: 40,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(20)),
                      child: const Text('Press Back again to leave'),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(TextTheme text) {
    final busy = library.sources.any((s) => library.statusOf(s.id).busy);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(busy ? 'Reading the channel list...' : 'No channels to show yet', style: text.headlineSmall),
          const SizedBox(height: 8),
          if (!busy) Text('Press OK to choose the groups to show.', style: text.bodyLarge?.copyWith(color: tvMuted)),
        ],
      ),
    );
  }

  Widget _errorCard(TextTheme text) {
    final (title, detail) = _error!;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 640),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(color: tvSurface.withAlpha(235), borderRadius: BorderRadius.circular(12)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_current?.name ?? '', style: text.bodyMedium?.copyWith(color: tvMuted)),
            Text(title, style: text.titleLarge?.copyWith(color: tvAlert)),
            const SizedBox(height: 6),
            Text(
              detail,
              style: text.bodySmall?.copyWith(color: tvMuted),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Text('Up / Down for another channel, OK for the guide.', style: text.bodySmall),
          ],
        ),
      ),
    );
  }

  String _programmeLine(Programme p, {required bool now}) {
    final start = formatTime(DateTime.fromMillisecondsSinceEpoch(p.start * 1000));
    final stop = formatTime(DateTime.fromMillisecondsSinceEpoch(p.stop * 1000));
    if (!now) return '$start  ${p.title}';
    final left = max(0, ((p.stop - nowSeconds()) / 60).ceil());
    return '$start - $stop  ${p.title}  ($left min left)';
  }

  Widget _infoBar(TextTheme text) {
    final ch = _current!;
    final (now, next) = library.nowNextFor(ch.uid);
    return Positioned(
      left: overscan.left,
      right: overscan.right,
      bottom: overscan.bottom,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: tvBackground.withAlpha(225), borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            ChannelLogo(url: ch.channel.logo, name: ch.name, size: 48),
            const SizedBox(width: 14),
            if (ch.channel.number != null) ...[
              Text('${ch.channel.number}', style: text.headlineSmall?.copyWith(color: tvMuted)),
              const SizedBox(width: 14),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(ch.name, style: text.titleLarge, overflow: TextOverflow.ellipsis),
                  if (now != null) ...[
                    Text(_programmeLine(now, now: true), style: text.bodyMedium, overflow: TextOverflow.ellipsis),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SizedBox(width: 260, child: ProgressLine(value: progressOf(now, nowSeconds()))),
                    ),
                  ],
                  if (next != null)
                    Text(
                      'Next  ${_programmeLine(next, now: false)}',
                      style: text.bodySmall?.copyWith(color: tvMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  Text('${ch.category}  -  ${ch.source.name}', style: text.bodySmall?.copyWith(color: tvMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
