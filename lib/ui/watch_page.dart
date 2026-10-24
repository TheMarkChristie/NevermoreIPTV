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
import '../core/player_state.dart';
import '../core/show_search.dart';
import '../core/presets.dart';
import '../core/setup_channel.dart';
import '../core/vpn.dart';
import '../core/web.dart';
import 'guide_view.dart';
import 'manage_channels_page.dart';
import 'settings_page.dart';
import 'tv.dart';
import 'web_page.dart';

const _startTimeout = Duration(seconds: 10);
const _zapSettle = Duration(milliseconds: 600);

class WatchPage extends StatefulWidget {
  const WatchPage({super.key, this.notice});

  /// Shown for a few seconds when the TV opens: what the install script set up.
  final String? notice;

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> {
  final _videoFocus = FocusNode(debugLabel: 'video');
  VideoPlayerController? _player;
  PlayableChannel? _current;
  int _token = 0;
  bool _starting = false;

  /// Which try of three is starting (said under the spinner, so a long start is not a silent one).
  int _attempt = 0;
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
    unawaited(_loadWeb());
    setupNotices.addListener(_onNotice);
    if (widget.notice != null) _showNotice(widget.notice!);
  }

  /// The guide's Web category (the house file's sites), after the TV's own.
  Category? _web;

  /// The TV's categories with the Web one after them: one list object until either changes, because GuideView rebuilds
  /// its grid whenever it is handed a different list (review, 24 Oct 2026).
  List<Category> _guideCategories = const [];

  void _mergeCategories() => _guideCategories = [..._categories, ?_web];

  /// The Web category at once, with the icons found on earlier starts; icons still missing arrive in the background.
  Future<void> _loadWeb() async {
    final sites = await loadSites();
    if (sites.isEmpty || !mounted) return;
    setState(() {
      _web = webCategory(sites, library.siteIcons);
      _mergeCategories();
    });
    final found = await findSiteIcons(sites, library.siteIcons);
    if (found.isEmpty || !mounted) return;
    await library.setSiteIcons({...library.siteIcons, ...found});
    if (!mounted) return;
    setState(() {
      _web = webCategory(sites, library.siteIcons);
      _mergeCategories();
    });
  }

  String? _notice;
  Timer? _noticeTimer;

  void _onNotice() {
    final text = setupNotices.value;
    if (text != null && mounted) _showNotice(text);
  }

  /// A line at the top for a few seconds (what the install script set up).
  void _showNotice(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void dispose() {
    library.removeListener(_onLibrary);
    vpn.removeListener(_onVpn);
    _life.dispose();
    _infoTimer?.cancel();
    _zapTimer?.cancel();
    _flashTimer?.cancel();
    _backTimer?.cancel();
    _noticeTimer?.cancel();
    setupNotices.removeListener(_onNotice);
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
    if (ch == null || _away || !mounted) return;
    if (!on && vpn.state == VpnState.failed) {
      // the tunnel went away under a playing channel: stop, rather than play on over the real address unnoticed
      _token++;
      _zapTimer?.cancel();
      unawaited(_stopPlayer());
      setState(() {
        _starting = false;
        _error = (
          'The VPN dropped',
          '${vpn.error ?? 'It stopped by itself.'}\nOK for the guide, then VPN to start it again.',
        );
      });
      return;
    }
    unawaited(_play(ch));
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
      _mergeCategories();
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
    _zapTimer?.cancel();
    unawaited(_stopPlayer());
  }

  void _onShow() {
    if (!_away) return;
    _away = false;
    final ch = _current;
    if (ch != null && ModalRoute.of(context)?.isCurrent == true) unawaited(_play(ch));
  }

  // ---- playing ----

  static const _screen = MethodChannel('nevermore/screen');
  bool _awake = false;

  /// The screen stays on while a channel plays, and only then: on a Google TV the screensaver took over the picture
  /// (Mark, 24 Oct 2026: "it seems that screensavers take over").
  void _keepAwake(bool on) {
    if (on == _awake) return;
    _awake = on;
    unawaited(_screen.invokeMethod<void>('awake', {'who': 'play', 'on': on}).catchError((_) {}));
  }

  Future<void> _stopPlayer() async {
    _keepAwake(false);
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
    if (p == null || ch == null || _starting) return;
    final v = p.value;
    // the stream dropped while watching, or ended without an error (a live stream has no end: the provider closed it):
    // start it again, with the usual retries
    if (!streamEnded(hasError: v.hasError, completed: v.isCompleted, playing: v.isPlaying, buffering: v.isBuffering)) {
      return;
    }
    unawaited(_play(ch, attempt: 1, error: v.errorDescription ?? 'the stream ended'));
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
      _attempt = attempt;
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
      if (token != _token) return;
      _keepAwake(true);
      // sound and no picture: a radio channel, shown with the radio sign from now on
      unawaited(library.markRadio(ch.uid, player.value.size.width == 0).catchError((_) {}));
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
    // a second 10 s timeout has shown that the network is not answering: no third try, the card comes sooner
    final timedOut = failure.contains('TimeoutException');
    if (!quick && attempt < 2 && !(timedOut && attempt == 1)) {
      if (mounted) setState(() => _attempt = attempt + 1);
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
    _flashLogo(next);
    _zapTimer?.cancel();
    _zapTimer = Timer(_zapSettle, () => _play(next));
  }

  PlayableChannel? _flash;
  Timer? _flashTimer;

  /// The new channel's logo in the middle of the screen for a second (Mark, 24 Oct 2026: "when we press up or down for
  /// the new channel it should flash up in the middle of the screen (the logo) for 1 second").
  void _flashLogo(PlayableChannel ch) {
    _flashTimer?.cancel();
    setState(() => _flash = ch);
    _flashTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _flash = null);
    });
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
    _infoTimer?.cancel();
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
    // a second OK while the stop is under way (a double press) would push a second page
    if (_away) return;
    _token++;
    _away = true;
    _zapTimer?.cancel();
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
      _token++;
      _zapTimer?.cancel();
      unawaited(_stopPlayer());
      // leaving the app takes the VPN down too: nothing else on the TV uses it (and not for long: the process ends)
      unawaited(vpn.turnOff().timeout(const Duration(seconds: 5), onTimeout: () {}).whenComplete(SystemNavigator.pop));
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
    if (player == null) return _starting ? _spinner(text, small) : const SizedBox.expand();
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: player,
      builder: (context, v, _) {
        if (!v.isInitialized) return _spinner(text, small);
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
        if (small || !library.pictureFill) {
          return Center(
            child: AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(player)),
          );
        }
        // Fill: scaled until it covers the screen, what does not fit cut at the edges
        return SizedBox.expand(
          child: FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(width: v.size.width, height: v.size.height, child: VideoPlayer(player)),
          ),
        );
      },
    );
  }

  /// A double tap on the picture (a phone): fitted whole, or filling the screen.
  Future<void> _togglePictureFill() async {
    final fill = !library.pictureFill;
    await library.setPictureFill(fill);
    if (!mounted) return;
    setState(() {});
    _showNotice(fill ? 'Picture: Fill (the edges are cut)' : 'Picture: Fit (the whole picture)');
  }

  /// The spinner with a word on what is happening: a start can take a while on a slow network, and three tries longer.
  Widget _spinner(TextTheme text, bool small) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (!small) ...[
            const SizedBox(height: 12),
            Text(
              _attempt == 0 ? 'Starting ${_current?.name ?? ''}...' : 'Trying again (${_attempt + 1} of 3)...',
              style: text.bodyMedium?.copyWith(color: tvMuted),
            ),
          ],
        ],
      ),
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
              if (!_guideOpen) _video(text),
              // over the picture, not around it: the picture is an Android view (0.5.4) and keeps the touches on it
              if (!_guideOpen)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openGuide,
                  onDoubleTap: () => unawaited(_togglePictureFill()),
                  // on a touch screen: swipe up for the next channel, down for the previous
                  onVerticalDragEnd: (d) {
                    final v = d.primaryVelocity ?? 0;
                    if (v < -300) _step(1);
                    if (v > 300) _step(-1);
                  },
                  child: const SizedBox.expand(),
                ),
              if (_all.isEmpty && !_guideOpen) _empty(text),
              if (_error != null && !_guideOpen) _errorCard(text),
              if (_flash != null && !_guideOpen)
                Center(
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: tvBackground.withAlpha(210),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: ChannelLogo(url: _flash!.channel.logo, name: _flash!.name, size: 160),
                    ),
                  ),
                ),
              if (_info && !_guideOpen && _current != null) _infoBar(text),
              if (_guideOpen)
                GuideView(
                  categories: _guideCategories,
                  all: _all,
                  category: _guideCategory,
                  playing: _current,
                  video: _video(text, small: true),
                  onPlay: (ch, category) {
                    // a site: the browser, with the TV stopped meanwhile
                    if (isWeb(ch)) {
                      unawaited(_leaveFor(WebPage(name: ch.name, url: ch.channel.url ?? '')));
                      return;
                    }
                    _autoStart = null;
                    _zapCategory = category;
                    _closeGuide();
                    unawaited(_play(ch));
                  },
                  onClose: _closeGuide,
                  onSettings: () => unawaited(_openSettings()),
                  onManage: (ch) => unawaited(_openManage(ch)),
                ),
              if (_notice != null)
                Positioned(
                  top: overscanOf(context).top,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(20)),
                      child: Text(_notice!, style: text.bodyMedium),
                    ),
                  ),
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
              style: text.bodyMedium?.copyWith(color: tvMuted),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            Text('Up / Down for another channel, OK for the guide.', style: text.bodyMedium),
          ],
        ),
      ),
    );
  }

  String _programmeLine(Programme p, {required bool now}) {
    final start = formatTime(DateTime.fromMillisecondsSinceEpoch(p.start * 1000));
    final stop = formatTime(DateTime.fromMillisecondsSinceEpoch(p.stop * 1000));
    if (!now) return '$start - $stop  ${p.title}';
    final left = max(0, ((p.stop - nowSeconds()) / 60).ceil());
    return '$start - $stop  ${p.title}  ($left min left)';
  }

  /// "Now   18:00 - 19:00  Title  (12 min left)" / "Next  19:00 - 19:30  Title" (Mark, 24 Oct 2026: "show from the EPG
  /// what is on now and what is on next with the times").
  Widget _programmeRow(TextTheme text, Programme p, {required bool now}) {
    final style = now ? text.bodyMedium : text.bodyMedium?.copyWith(color: tvMuted);
    return Row(
      children: [
        SizedBox(
          width: 52,
          child: Text(now ? 'Now' : 'Next', style: style?.copyWith(fontWeight: FontWeight.w700)),
        ),
        Expanded(
          child: Text(
            _programmeLine(p, now: now),
            style: style,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _infoBar(TextTheme text) {
    final ch = _current!;
    final (now, next) = library.nowNextFor(ch.uid);
    return Positioned(
      left: overscanOf(context).left,
      right: overscanOf(context).right,
      bottom: overscanOf(context).bottom,
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
                  Row(
                    children: [
                      Flexible(
                        child: Text(ch.name, style: text.titleLarge, overflow: TextOverflow.ellipsis),
                      ),
                      if (library.isRadio(ch)) ...[
                        const SizedBox(width: 10),
                        const Icon(Icons.radio, size: 22, color: tvMuted),
                      ],
                    ],
                  ),
                  if (now != null) ...[
                    _programmeRow(text, now, now: true),
                    Padding(
                      padding: const EdgeInsets.only(left: 52, top: 4, bottom: 4),
                      child: SizedBox(width: 260, child: ProgressLine(value: progressOf(now, nowSeconds()))),
                    ),
                  ],
                  if (next != null) _programmeRow(text, next, now: false),
                  // said rather than left out, so a channel without a guide is told from a bar without one
                  if (now == null && next == null)
                    Text(
                      library.guideBusy && library.programmes.isEmpty
                          ? 'Reading the guide...'
                          : 'No guide information for this channel',
                      style: text.bodyMedium?.copyWith(color: tvMuted),
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
