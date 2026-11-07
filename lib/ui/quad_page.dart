/// The four screens (0.8.0). Mark, 6 Nov 2026: "on the 4 screens at once whichever section is highlighted needs to be
/// the audio. When switching the 4 play it also needs to put the channel that was on in one then have the epg in the
/// other 3, and I need to be able to use and change the epg like normal in each box and because they won't fit
/// perfectly on the screen it is ok to have a background image under it for formatting with a number 4 and the word
/// okay underneath it in the middle". His answers of 7 Nov: the "4 / OK" mark is the way in (4 on the remote, then
/// OK, while watching); a held OK on a box offers Full screen and Guide here; the boxes play the smaller copies
/// (copies.dart smallerCopy: SD, else HD, else FHD) and a provider's stream limit keeps a box on the guide; the raven
/// backdrop (tools/make_backdrop.py) under the grid.
///
/// Keys: 1 to 4 highlight a box (its sound comes on, the others go quiet); without number keys (Mark, 7 Nov 2026: "Not
/// many remotes have numbers on them") the arrows do: on a picture box they move the highlight, and in a guide box Up
/// from the bar, Left past All or Right past Settings move it on (the guide's edges). In a guide box the other keys are
/// the guide's as ever; OK on a channel plays it in that box. On a picture box OK (or a held OK) offers Full screen and
/// Guide here, Back puts its guide back. Back with all four boxes on the guide leaves, to the channel from before.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/copies.dart';
import '../core/library.dart';
import '../core/model.dart';
import 'guide_view.dart';
import 'tv.dart';

/// How the four screens were left: the channel for the full screen (null: the one from before), or a page to open.
class QuadLeave {
  const QuadLeave({this.channel, this.settings = false, this.manage, this.site});

  final PlayableChannel? channel;
  final bool settings;
  final PlayableChannel? manage;
  final PlayableChannel? site;
}

class QuadPage extends StatefulWidget {
  const QuadPage({super.key, required this.categories, required this.all, this.start});

  final List<Category> categories;
  final List<PlayableChannel> all;

  /// The channel playing before: the first box starts with it.
  final PlayableChannel? start;

  @override
  State<QuadPage> createState() => _QuadPageState();
}

class _Box {
  PlayableChannel? channel;

  /// The smaller copy playing in the channel's place, when the provider has one.
  Channel? copy;
  VideoPlayerController? player;
  bool starting = false;
  String? problem;
  int token = 0;

  bool get picture => channel != null;
}

class _QuadPageState extends State<QuadPage> {
  final _boxes = List.generate(4, (_) => _Box());
  int _highlight = 0;
  final _keys = FocusNode(debugLabel: 'quad');
  bool _selectHeld = false;
  String? _note;
  Timer? _noteTimer;

  @override
  void initState() {
    super.initState();
    final start = widget.start;
    if (start != null) unawaited(_startBox(0, start));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusHighlight();
      _say('Arrows past the edge of a box move to another  -  OK on a picture: Full screen  -  1 to 4 pick a box');
    });
  }

  @override
  void dispose() {
    _noteTimer?.cancel();
    for (final box in _boxes) {
      box.token++;
      unawaited(box.player?.dispose());
      box.player = null;
    }
    _keys.dispose();
    super.dispose();
  }

  /// A line at the top for a few seconds.
  void _say(String what) {
    _noteTimer?.cancel();
    setState(() => _note = what);
    _noteTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _note = null);
    });
  }

  /// The highlighted box has the keys: a picture box through this page's node, a guide box through its guide.
  void _focusHighlight() {
    if (!mounted) return;
    if (!_boxes[_highlight].picture) return;
    _keys.requestFocus();
  }

  void _setHighlight(int i) {
    if (i < 0 || i > 3) return;
    setState(() => _highlight = i);
    for (final (j, box) in _boxes.indexed) {
      unawaited(box.player?.setVolume(j == i ? 1 : 0).catchError((_) {}));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusHighlight());
  }

  Future<void> _stopBox(_Box box) async {
    final p = box.player;
    box.player = null;
    if (p != null) await p.dispose();
  }

  /// Why [ch] cannot start in box [i] now: the provider's streams-at-once limit, with the other boxes counted.
  String? _limitProblem(int i, PlayableChannel ch) {
    if (!ch.source.isXtream) return null;
    final account = library.statusOf(ch.source.id).account;
    final max = account?.max ?? 0;
    if (max <= 0) return null;
    var used = 0;
    for (final (j, box) in _boxes.indexed) {
      if (j != i && box.channel?.source.id == ch.source.id && (box.player != null || box.starting)) used++;
    }
    if (used < max) return null;
    return 'Your provider allows $max stream${max == 1 ? '' : 's'} at once: this box stays on the guide';
  }

  /// [ch] in box [i], as its smaller copy where the provider has one.
  Future<void> _startBox(int i, PlayableChannel ch) async {
    final box = _boxes[i];
    final limit = _limitProblem(i, ch);
    if (limit != null) {
      _say(limit);
      return;
    }
    final token = ++box.token;
    await _stopBox(box);
    if (!mounted || token != box.token) return;
    final catalog = library.catalogs[ch.source.id];
    final copy = catalog == null ? ch.channel : smallerCopy(catalog, ch.channel);
    setState(() {
      box.channel = ch;
      box.copy = copy.key == ch.channel.key ? null : copy;
      box.starting = true;
      box.problem = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusHighlight());
    try {
      final address = await library.streamFor(PlayableChannel(ch.source, copy, ch.name, ch.category));
      if (token != box.token) return;
      final player = VideoPlayerController.networkUrl(
        Uri.parse(address.url),
        formatHint: address.hls ? VideoFormat.hls : null,
        httpHeaders: address.headers,
        viewType: VideoViewType.platformView,
      );
      box.player = player;
      await player.initialize().timeout(const Duration(seconds: 20));
      if (token != box.token) {
        await player.dispose();
        return;
      }
      await player.setVolume(i == _highlight ? 1 : 0);
      await player.play();
      if (mounted) setState(() => box.starting = false);
    } catch (err) {
      if (token != box.token) return;
      await _stopBox(box);
      // the usual words for a failure (library.explainFailure), not the player's own
      final (title, detail) = await library.explainFailure(ch, '$err');
      if (mounted && token == box.token) {
        setState(() {
          box.starting = false;
          box.problem = detail.isEmpty ? title : '$title\n$detail';
        });
      }
    }
  }

  /// Box [i] shows the guide again.
  Future<void> _guideBack(int i) async {
    final box = _boxes[i];
    box.token++;
    await _stopBox(box);
    if (!mounted) return;
    setState(() {
      box.channel = null;
      box.copy = null;
      box.starting = false;
      box.problem = null;
    });
  }

  Future<void> _leave(QuadLeave how) async {
    for (final box in _boxes) {
      box.token++;
      await _stopBox(box);
    }
    if (mounted) Navigator.of(context).pop(how);
  }

  /// A picture box's choices.
  Future<void> _boxMenu(int i) async {
    final box = _boxes[i];
    final ch = box.channel;
    if (ch == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tvSurface,
        title: Text(ch.name),
        actions: [
          TvButton(
            label: 'Full screen',
            autofocus: true,
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_leave(QuadLeave(channel: ch)));
            },
          ),
          TvButton(
            label: 'Guide here',
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(_guideBack(i));
            },
          ),
          TvButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
    _focusHighlight();
  }

  void _onBack() {
    final box = _boxes[_highlight];
    if (box.picture) {
      unawaited(_guideBack(_highlight));
      return;
    }
    if (_boxes.every((b) => !b.picture)) {
      unawaited(_leave(const QuadLeave()));
      return;
    }
    _say('Arrows past the edge of a box move on  -  OK on a picture: Full screen  -  Back with four guides leaves');
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final k = event.logicalKey;
    final digit = event.character ?? k.keyLabel.replaceFirst('Numpad ', '');
    // 1 to 4: that box, from anywhere (a guide's keys leave the digits alone)
    if (event is KeyDownEvent && RegExp(r'^[1-4]$').hasMatch(digit)) {
      _setHighlight(int.parse(digit) - 1);
      return KeyEventResult.handled;
    }
    // arrows reach here from a picture box, or from a guide box's edge (Up from its bar, Left past All, Right past
    // Settings): the highlight moves to the box beside or above / below, round the ring
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final next = switch (k) {
        LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowRight => _highlight ^ 1,
        LogicalKeyboardKey.arrowUp || LogicalKeyboardKey.arrowDown => _highlight ^ 2,
        _ => -1,
      };
      if (next >= 0) {
        _setHighlight(next);
        return KeyEventResult.handled;
      }
    }
    // the rest is for a picture box (a guide box's keys are the guide's)
    if (!_boxes[_highlight].picture) return KeyEventResult.ignored;
    final select =
        k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.gameButtonA;
    if (select) {
      // the menu on the way up, so a held OK (its repeats) opens it once, as a short OK does
      if (event is KeyDownEvent) {
        _selectHeld = true;
      } else if (event is KeyUpEvent && _selectHeld) {
        _selectHeld = false;
        unawaited(_boxMenu(_highlight));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const gap = 16.0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        backgroundColor: tvBackground,
        body: Focus(
          focusNode: _keys,
          onKeyEvent: _onKey,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset('assets/brand/backdrop.png', fit: BoxFit.cover),
              Padding(
                padding: overscanOf(context),
                child: Column(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: _box(text, 0)),
                          const SizedBox(width: gap),
                          Expanded(child: _box(text, 1)),
                        ],
                      ),
                    ),
                    const SizedBox(height: gap),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: _box(text, 2)),
                          const SizedBox(width: gap),
                          Expanded(child: _box(text, 3)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // the mark in the middle: the way in, as a reminder
              Center(
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: tvBackground.withAlpha(230),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: tvAccent, width: 1.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('4', style: text.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                        Text('OK', style: text.bodySmall?.copyWith(color: tvMuted)),
                      ],
                    ),
                  ),
                ),
              ),
              if (_note != null)
                Positioned(
                  top: overscanOf(context).top,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(20)),
                      child: Text(_note!, style: text.bodyMedium),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _box(TextTheme text, int i) {
    final box = _boxes[i];
    final on = i == _highlight;
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: on ? Colors.white : tvSurface, width: on ? 3 : 2),
      ),
      child: box.picture ? _picture(text, i, box, on) : _guide(i, on),
    );
  }

  /// The full guide, scaled into the box; only the highlighted box's takes the keys.
  Widget _guide(int i, bool on) {
    final screen = MediaQuery.sizeOf(context);
    return FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: screen.width,
        height: screen.height,
        child: GuideView(
          categories: widget.categories,
          all: widget.all,
          category: 0,
          playing: null,
          active: on,
          inBox: true,
          video: const SizedBox.shrink(),
          onPlay: (ch, _) => unawaited(_startBox(i, ch)),
          onClose: _onBack,
          onSettings: () => unawaited(_leave(const QuadLeave(settings: true))),
          onManage: (ch) => unawaited(_leave(QuadLeave(manage: ch))),
          onOpenSite: (ch) => unawaited(_leave(QuadLeave(site: ch))),
        ),
      ),
    );
  }

  Widget _picture(TextTheme text, int i, _Box box, bool on) {
    final player = box.player;
    final ch = box.channel!;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (box.problem != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                box.problem!,
                style: text.bodyMedium?.copyWith(color: tvAlert),
                textAlign: TextAlign.center,
              ),
            ),
          )
        else if (player == null || box.starting)
          const Center(child: CircularProgressIndicator())
        else
          ValueListenableBuilder<VideoPlayerValue>(
            valueListenable: player,
            builder: (context, v, _) {
              if (!v.isInitialized) return const Center(child: CircularProgressIndicator());
              if (v.size.width == 0) return const Center(child: Icon(Icons.radio, size: 40, color: tvMuted));
              return Center(
                child: AspectRatio(aspectRatio: v.aspectRatio, child: VideoPlayer(player)),
              );
            },
          ),
        if (on)
          Positioned(
            left: 10,
            bottom: 10,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: tvBackground.withAlpha(215), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  box.copy == null ? ch.name : '${ch.name}  -  ${qualityWord(box.copy!.name)} copy',
                  style: text.bodySmall,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
