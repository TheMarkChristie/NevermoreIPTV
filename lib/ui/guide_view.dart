/// The guide over the video (design, section 4): the categories along the top, the channel playing in a small window
/// beside the focused programme's details, and the grid below - channels down, two hours across, half-hour marks and a
/// line at now, from half an hour back to twelve hours ahead. It opens on the channel playing.
///
/// Keys: Up / Down move between channels (up from the first reaches the categories), Left / Right through programmes
/// (on the categories: another category), channel up / down a page, OK on a programme on now plays that channel, OK on a
/// later one shows its details, holding OK (a long press) offers Manage channels for that channel's group. Search, at
/// the end of the categories, finds a show: one on now plays, a later one opens the guide at it. Moving around never
/// changes what is playing, so browsing never opens a second connection.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/guide_grid.dart';
import '../core/library.dart';
import '../core/model.dart';
import '../core/show_search.dart';
import '../core/vpn.dart';
import 'show_search_page.dart';
import 'tv.dart';
import 'vpn_card.dart';

const _rowHeight = 44.0;
const _nowLine = Color(0xFFE5484D);

class GuideView extends StatefulWidget {
  const GuideView({
    super.key,
    required this.categories,
    required this.all,
    required this.category,
    required this.playing,
    required this.video,
    required this.onPlay,
    required this.onClose,
    required this.onSettings,
    required this.onManage,
  });

  final List<Category> categories;
  final List<PlayableChannel> all;

  /// 0: All; else the index into [categories] plus one.
  final int category;
  final PlayableChannel? playing;
  final Widget video;

  /// A channel to watch, and the category it was picked from (null: All).
  final void Function(PlayableChannel channel, String? category) onPlay;
  final VoidCallback onClose;
  final VoidCallback onSettings;
  final void Function(PlayableChannel channel) onManage;

  @override
  State<GuideView> createState() => _GuideViewState();
}

class _GuideViewState extends State<GuideView> {
  final _focus = FocusNode(debugLabel: 'guide');
  final _rows = ScrollController();
  final _bar = ScrollController();
  late int _category = widget.category.clamp(0, widget.categories.length);
  late GuideGrid _grid;
  bool _onBar = false;
  late int _barIndex = _category;
  bool _selectHeld = false;
  bool _longDone = false;
  Timer? _clock;

  // Up three times in quick succession: straight to the categories (Mark, 22 Oct 2026)
  static const _quickUp = Duration(milliseconds: 400);
  int _ups = 0;
  DateTime? _upAt;
  int _upRow = 0;

  // a phone held upright: the preview over the details, and a narrower channel column (no numbers) so the
  // programmes keep room
  bool _upright = false;

  double get _labelWidth => _upright ? 150.0 : 230.0;

  int get _searchIndex => widget.categories.length + 1;

  int get _vpnIndex => widget.categories.length + 2;

  int get _settingsIndex => widget.categories.length + 3;

  List<PlayableChannel> get _channels => _category == 0 ? widget.all : widget.categories[_category - 1].channels;

  String? get _categoryName => _category == 0 ? null : widget.categories[_category - 1].name;

  PlayableChannel? get _focused => _channels.isEmpty ? null : _channels[_grid.row];

  @override
  void initState() {
    super.initState();
    vpn.addListener(_onVpn);
    _buildGrid(atUid: widget.playing?.uid);
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _scrollToRow();
    });
    _scrollBar();
  }

  @override
  void didUpdateWidget(GuideView old) {
    super.didUpdateWidget(old);
    // new lists or a new guide: keep the cursor on the same channel and moment
    if (old.categories != widget.categories || old.all != widget.all) {
      if (_category > widget.categories.length) _category = 0;
      final uid = _focused?.uid;
      final time = _grid.time;
      _buildGrid(atUid: uid);
      _grid.time = time.clamp(_grid.minTime, _grid.maxTime - 1);
    }
  }

  void _onVpn() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    vpn.removeListener(_onVpn);
    _clock?.cancel();
    _focus.dispose();
    _rows.dispose();
    _bar.dispose();
    super.dispose();
  }

  void _buildGrid({String? atUid}) {
    final channels = _channels;
    final at = atUid == null ? -1 : channels.indexWhere((c) => c.uid == atUid);
    _grid = GuideGrid(
      rows: [for (final c in channels) library.programmesFor(c.uid)],
      now: nowSeconds(),
      row: max(0, at),
    );
  }

  void _setCategory(int index) {
    if (index == _category || index < 0 || index > widget.categories.length) return;
    final time = _grid.time;
    setState(() {
      _category = index;
      _buildGrid(atUid: widget.playing?.uid);
      _grid.time = time.clamp(_grid.minTime, _grid.maxTime - 1);
    });
    _scrollToRow();
  }

  void _scrollToRow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_rows.hasClients) return;
      final view = _rows.position.viewportDimension;
      final top = _grid.row * _rowHeight;
      final offset = _rows.offset;
      // a row's margin above and below the focused one, where the screen has room for it
      final margin = view >= 3 * _rowHeight ? _rowHeight : 0.0;
      double? to;
      if (top - margin < offset) {
        to = top - margin;
      } else if (top + _rowHeight + margin > offset + view) {
        to = top + _rowHeight + margin - view;
      }
      if (to != null) _rows.jumpTo(to.clamp(0.0, _rows.position.maxScrollExtent));
    });
  }

  void _scrollBar() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_bar.hasClients) return;
      final ctx = _barKeys[_barIndex]?.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 120));
    });
  }

  /// Onto the categories, at the one showing, scrolled into view.
  void _toBar() {
    _onBar = true;
    _barIndex = _category;
    _ups = 0;
    _scrollBar();
  }

  final Map<int, GlobalKey> _barKeys = {};
  double? _gridHeight;

  bool _isSelect(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final k = event.logicalKey;
    // OK: a short press acts on release; held, it offers the options
    if (_isSelect(k)) {
      if (event is KeyDownEvent) {
        _selectHeld = true;
        _longDone = false;
      } else if (event is KeyRepeatEvent) {
        if (_selectHeld && !_longDone) {
          _longDone = true;
          _options();
        }
      } else if (event is KeyUpEvent) {
        if (_selectHeld && !_longDone) _activate();
        _selectHeld = false;
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.contextMenu) {
      _options();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.guide) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (_onBar) {
      if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight) {
        final next = (_barIndex + (k == LogicalKeyboardKey.arrowLeft ? -1 : 1)).clamp(0, _settingsIndex);
        setState(() => _barIndex = next);
        if (next <= widget.categories.length) _setCategory(next);
        _scrollBar();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        setState(() => _onBar = false);
        return KeyEventResult.handled;
      }
      return k == LogicalKeyboardKey.arrowUp ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      // a held Up only scrolls; the third of three quick presses goes back to the channel it started from (so Down
      // returns there) and up to the categories
      final now = DateTime.now();
      if (event is KeyDownEvent) {
        if (_upAt == null || now.difference(_upAt!) > _quickUp) {
          _ups = 0;
          _upRow = _grid.row;
        }
        _ups++;
        _upAt = now;
      } else {
        _ups = 0;
      }
      setState(() {
        if (_ups >= 3) {
          _grid.row = _upRow.clamp(0, max(0, _channels.length - 1));
          _toBar();
        } else if (!_grid.up()) {
          _toBar();
        }
      });
    } else if (k == LogicalKeyboardKey.arrowDown) {
      setState(_grid.down);
    } else if (k == LogicalKeyboardKey.arrowLeft) {
      setState(_grid.left);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      setState(_grid.right);
    } else if (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.channelUp) {
      setState(_grid.pageUp);
    } else if (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.channelDown) {
      setState(_grid.pageDown);
    } else {
      return KeyEventResult.ignored;
    }
    _scrollToRow();
    return KeyEventResult.handled;
  }

  void _activate() {
    if (_onBar) {
      if (_barIndex == _settingsIndex) {
        widget.onSettings();
      } else if (_barIndex == _searchIndex) {
        unawaited(_search());
      } else if (_barIndex == _vpnIndex) {
        unawaited(_vpnButton());
      } else {
        setState(() => _onBar = false);
      }
      return;
    }
    final ch = _focused;
    if (ch == null) return;
    final p = _grid.cell?.programme;
    final now = nowSeconds();
    if (p == null || (p.start <= now && now < p.stop) || p.stop <= now) {
      widget.onPlay(ch, _categoryName);
    } else {
      unawaited(_details(ch, p));
    }
  }

  /// The VPN item: on / off in one press; without a WireGuard file yet, Add a WireGuard file.
  Future<void> _vpnButton() async {
    if (vpn.settings != null) {
      await vpn.toggle();
      return;
    }
    await openVpnAdd(context);
    if (mounted) _focus.requestFocus();
  }

  /// Search for a show: one on now plays; a later one opens the guide at it (All, its channel, its time).
  Future<void> _search() async {
    final pick = await searchForShow(context);
    if (!mounted) return;
    _focus.requestFocus();
    if (pick == null) return;
    final (ch, p) = pick;
    final now = nowSeconds();
    if (p.start <= now && now < p.stop) {
      widget.onPlay(ch, null);
      return;
    }
    setState(() {
      _onBar = false;
      _category = 0;
      _barIndex = 0;
      _buildGrid(atUid: ch.uid);
      _grid.focusTime(p.start);
    });
    _scrollToRow();
  }

  Future<void> _details(PlayableChannel ch, Programme p) async {
    final text = Theme.of(context).textTheme;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tvSurface,
        title: Text(p.title),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${ch.name}  -  ${_timeLine(p)}', style: text.bodyMedium?.copyWith(color: tvMuted)),
              if (p.sub.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(p.sub)),
              if (p.category.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(p.category, style: text.bodySmall?.copyWith(color: tvMuted)),
                ),
              if (p.desc.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(p.desc)),
            ],
          ),
        ),
        actions: [
          TvButton(label: 'Close', autofocus: true, onPressed: () => Navigator.of(context).pop()),
          TvButton(
            label: 'Watch ${ch.name} now',
            onPressed: () {
              Navigator.of(context).pop();
              widget.onPlay(ch, _categoryName);
            },
          ),
        ],
      ),
    );
    _focus.requestFocus();
  }

  Future<void> _options() async {
    final ch = _focused;
    if (_onBar || ch == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tvSurface,
        title: Text(ch.name),
        actions: [
          TvButton(
            label: 'Manage ${ch.category} channels',
            autofocus: true,
            onPressed: () {
              Navigator.of(context).pop();
              widget.onManage(ch);
            },
          ),
          TvButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
    _focus.requestFocus();
  }

  String _timeLine(Programme p) {
    final now = nowSeconds();
    final start = DateTime.fromMillisecondsSinceEpoch(p.start * 1000);
    final stop = DateTime.fromMillisecondsSinceEpoch(p.stop * 1000);
    final span = '${formatTime(start)} - ${formatTime(stop)}';
    if (p.start <= now && now < p.stop) return '$span  -  ${((p.stop - now) / 60).ceil()} min left';
    if (p.start > now) {
      final mins = ((p.start - now) / 60).round();
      return '$span  -  in ${mins >= 60 ? '${mins ~/ 60} h ${mins % 60} min' : '$mins min'}';
    }
    return span;
  }

  // ---- drawing ----

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    _upright = isUpright(context);
    // the top panel gives way on a short screen so the grid keeps four rows or more
    final top = (MediaQuery.sizeOf(context).height * 0.28).clamp(96.0, 150.0);
    final preview = ColoredBox(color: Colors.black, child: widget.video);
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Container(
        color: tvBackground,
        padding: overscanOf(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_upright) ...[
              AspectRatio(aspectRatio: 16 / 9, child: preview),
              const SizedBox(height: 10),
              SizedBox(height: 100, child: ClipRect(child: _detailsPanel(text, descLines: 1))),
            ] else
              SizedBox(
                height: top,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: top * 16 / 9, height: top, child: preview),
                    const SizedBox(width: 18),
                    // clipped: on a short screen the description gives way, never the categories
                    Expanded(
                      child: ClipRect(child: _detailsPanel(text, descLines: top >= 140 ? 3 : 1)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(height: 40, child: _categoryBar(text)),
            const SizedBox(height: 6),
            Expanded(child: _gridArea(text)),
          ],
        ),
      ),
    );
  }

  Widget _detailsPanel(TextTheme text, {int descLines = 3}) {
    if (_onBar) {
      final hint = _barIndex == _searchIndex
          ? 'OK: search the guide for a show.'
          : _barIndex == _vpnIndex
          ? (vpn.error ?? (vpn.settings == null ? 'OK: add a WireGuard file.' : 'OK: turn the VPN on or off.'))
          : _barIndex == _settingsIndex
          ? 'OK: Settings.'
          : 'Left / Right: another category.  Down: its channels.';
      return Text(hint, style: text.bodyMedium?.copyWith(color: tvMuted));
    }
    final ch = _focused;
    if (ch == null) return Text('No channels in this category', style: text.titleMedium);
    final p = _grid.cell?.programme;
    final now = nowSeconds();
    final reading = p == null && library.guideBusy && library.programmes.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${ch.channel.number == null ? '' : '${ch.channel.number}  '}${ch.name}',
          style: text.bodyMedium?.copyWith(color: tvMuted),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          p?.title ?? (reading ? 'Reading the guide...' : 'No guide information'),
          style: text.titleLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (p != null) Text(_timeLine(p), style: text.bodySmall?.copyWith(color: tvMuted)),
        if (p != null && p.start <= now && now < p.stop)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: SizedBox(width: 220, child: ProgressLine(value: progressOf(p, now))),
          ),
        if (p != null && (p.sub.isNotEmpty || p.category.isNotEmpty))
          Text(
            [p.sub, p.category].where((s) => s.isNotEmpty).join('  -  '),
            style: text.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        if (p != null && p.desc.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              p.desc,
              style: text.bodySmall?.copyWith(color: tvMuted),
              maxLines: descLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }

  Widget _categoryBar(TextTheme text) {
    final names = ['All', for (final c in widget.categories) c.name, 'Search', vpn.label, 'Settings'];
    return ListView.builder(
      controller: _bar,
      scrollDirection: Axis.horizontal,
      itemCount: names.length,
      itemBuilder: (context, i) {
        final focused = _onBar && i == _barIndex;
        final picked = i == _category;
        return Padding(
          key: _barKeys.putIfAbsent(i, GlobalKey.new),
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: () => i == _settingsIndex
                ? widget.onSettings()
                : i == _searchIndex
                ? unawaited(_search())
                : i == _vpnIndex
                ? unawaited(_vpnButton())
                : _setCategory(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: focused ? Colors.white : (picked ? tvSurface : Colors.transparent),
                border: Border.all(color: focused ? Colors.white : (picked ? tvAccent : Colors.white24), width: 2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  if (i >= _searchIndex) ...[
                    Icon(
                      i == _searchIndex
                          ? Icons.search
                          : i == _vpnIndex
                          ? (vpn.state == VpnState.on ? Icons.vpn_lock : Icons.vpn_key_off_outlined)
                          : Icons.settings,
                      size: 16,
                      color: focused ? Colors.black : Colors.white,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(names[i], style: text.bodyMedium?.copyWith(color: focused ? Colors.black : Colors.white)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _gridArea(TextTheme text) {
    return LayoutBuilder(
      builder: (context, box) {
        // the grid's room changed (first layout, a smaller screen): keep the focused row in view
        if (box.maxHeight != _gridHeight) {
          _gridHeight = box.maxHeight;
          _scrollToRow();
        }
        final perSecond = (box.maxWidth - _labelWidth) / gridSpan;
        final now = nowSeconds();
        final channels = _channels;
        return Column(
          children: [
            SizedBox(height: 20, child: _timeHeader(text, perSecond)),
            Expanded(
              child: Stack(
                children: [
                  ListView.builder(
                    controller: _rows,
                    itemExtent: _rowHeight,
                    itemCount: channels.length,
                    itemBuilder: (context, i) => _row(text, i, channels[i], perSecond, now),
                  ),
                  if (now >= _grid.windowStart && now < _grid.windowEnd)
                    Positioned(
                      left: _labelWidth + (now - _grid.windowStart) * perSecond,
                      top: 0,
                      bottom: 0,
                      child: const IgnorePointer(
                        child: SizedBox(width: 2, child: ColoredBox(color: _nowLine)),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _timeHeader(TextTheme text, double perSecond) {
    final marks = <Widget>[];
    for (var t = halfHourFloor(_grid.windowStart); t < _grid.windowEnd; t += 1800) {
      if (t < _grid.windowStart) continue;
      marks.add(
        Positioned(
          left: _labelWidth + (t - _grid.windowStart) * perSecond + 4,
          top: 0,
          child: Text(
            formatTime(DateTime.fromMillisecondsSinceEpoch(t * 1000)),
            style: text.bodySmall?.copyWith(color: tvMuted),
          ),
        ),
      );
    }
    return Stack(children: marks);
  }

  Widget _row(TextTheme text, int i, PlayableChannel ch, double perSecond, int now) {
    final playing = ch.uid == widget.playing?.uid;
    final focusedRow = !_onBar && i == _grid.row;
    final focusedCell = focusedRow ? _grid.cell : null;
    final cells = [
      for (final c in _grid.cellsOf(i))
        if (c.stop > _grid.windowStart && c.start < _grid.windowEnd) c,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: _labelWidth,
            child: GestureDetector(
              onTap: () => widget.onPlay(ch, _categoryName),
              // a long press is the touch screen's held OK: Manage channels for that group
              onLongPress: () {
                setState(() {
                  _onBar = false;
                  _grid.row = i;
                });
                unawaited(_options());
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: focusedRow ? tvSurface : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    ChannelLogo(url: ch.channel.logo, name: ch.name, size: 28),
                    const SizedBox(width: 8),
                    if (!_upright)
                      SizedBox(
                        width: 40,
                        child: Text(
                          ch.channel.number == null ? '' : '${ch.channel.number}',
                          style: text.bodySmall?.copyWith(color: tvMuted),
                          overflow: TextOverflow.clip,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        ch.name,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(
                          color: playing ? tvAccent : Colors.white,
                          fontWeight: playing ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (library.isRadio(ch)) const Icon(Icons.radio, size: 16, color: tvMuted),
                    if (playing) const Icon(Icons.play_arrow, size: 16, color: tvAccent),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: Stack(
                children: [
                  for (final c in cells)
                    Positioned(
                      left: (max(c.start, _grid.windowStart) - _grid.windowStart) * perSecond,
                      width: max(2.0, (min(c.stop, _grid.windowEnd) - max(c.start, _grid.windowStart)) * perSecond - 3),
                      top: 0,
                      bottom: 0,
                      child: GestureDetector(
                        onTap: () {
                          setState(() {
                            _onBar = false;
                            _grid
                              ..row = i
                              ..time = c.start;
                          });
                          _activate();
                        },
                        child: _cellBox(text, c, identical(c, focusedCell), now),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cellBox(TextTheme text, GridCell c, bool focused, int now) {
    final p = c.programme;
    final onNow = p != null && p.start <= now && now < p.stop;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: focused
            ? Colors.white
            : p == null
            ? const Color(0xFF15171B)
            : (onNow ? const Color(0xFF2A2F38) : tvSurface),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              p?.title ?? (focused ? 'No information' : ''),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(color: focused ? Colors.black : (p == null ? tvMuted : Colors.white)),
            ),
          ),
          // how far through the programme on now is, across the whole cell
          if (onNow)
            Positioned(
              left: -8,
              right: -8,
              bottom: 0,
              child: ProgressLine(value: progressOf(p, now), height: 2, color: focused ? tvAccent : _nowLine),
            ),
        ],
      ),
    );
  }
}
