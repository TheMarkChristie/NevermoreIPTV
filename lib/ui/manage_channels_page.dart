/// One group's channels (or a search's): tick single channels (an untick overrides the group; Follow group undoes
/// it), Rename, Move (Up / Down carry the channel, OK puts it down), Guide (the match, Change guide, Automatic) and
/// Preview.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/library.dart';
import '../core/model.dart';
import 'guide_pick_page.dart';
import 'tv.dart';

class ManageChannelsPage extends StatefulWidget {
  const ManageChannelsPage({super.key, required this.sourceId, this.groupId, this.keys, this.title});

  final String sourceId;

  /// A group's channels, in this TV's order (they can be moved)...
  final String? groupId;

  /// ...or a search's (they cannot).
  final List<String>? keys;
  final String? title;

  @override
  State<ManageChannelsPage> createState() => _ManageChannelsPageState();
}

class _ManageChannelsPageState extends State<ManageChannelsPage> {
  String? _moving;
  List<String> _order = [];

  List<Channel> _channels() {
    final cat = library.catalogs[widget.sourceId];
    if (cat == null) return const [];
    final keys = widget.keys;
    if (keys != null) {
      final byKey = {for (final c in cat.channels) c.key: c};
      return [for (final k in keys) ?byKey[k]];
    }
    final listed = orderedChannels(cat, library.selectionOf(widget.sourceId), widget.groupId!);
    if (_moving == null) _order = [for (final c in listed) c.key];
    final byKey = {for (final c in listed) c.key: c};
    return [for (final k in _order) ?byKey[k]];
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = _moving;
    if (key == null || event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final at = _order.indexOf(key);
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final to = at + (k == LogicalKeyboardKey.arrowUp ? -1 : 1);
      if (at >= 0 && to >= 0 && to < _order.length) {
        setState(() {
          _order
            ..removeAt(at)
            ..insert(to, key);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = FocusManager.instance.primaryFocus?.context;
          if (ctx != null) Scrollable.ensureVisible(ctx, alignment: 0.5);
        });
      }
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.gameButtonA)) {
      unawaited(_drop());
      return KeyEventResult.handled;
    }
    return k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.arrowRight
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  Future<void> _drop() async {
    if (_moving == null) return;
    final order = List.of(_order);
    setState(() => _moving = null);
    await library.change(widget.sourceId, [
      {'order': order},
    ]);
  }

  Future<void> _rename(Channel c, String shown) async {
    final name = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            TextEntryPage(label: 'Rename ${c.name}', initial: shown, hint: 'Leave it empty for the provider\'s name'),
      ),
    );
    if (name != null) {
      await library.change(widget.sourceId, [
        {'channel': c.key, 'name': name},
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: _moving == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_drop());
      },
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) {
          final source = library.sourceById(widget.sourceId);
          final cat = library.catalogs[widget.sourceId];
          final sel = library.selectionOf(widget.sourceId);
          final group = widget.groupId == null ? null : cat?.group(widget.groupId!);
          final channels = _channels();
          final title = widget.title ?? (group == null ? 'Channels' : withoutMarks(groupName(group, sel)));
          return Scaffold(
            backgroundColor: tvBackground,
            body: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: Padding(
                padding: overscanOf(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$title  -  ${source?.name ?? ''}',
                            style: text.headlineSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TvButton(label: 'Done', onPressed: () => Navigator.of(context).maybePop()),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _moving != null
                          ? 'Up / Down move the channel. OK puts it down.'
                          : 'OK ticks or unticks a channel; a channel\'s own tick overrides its group\'s.',
                      style: text.bodyMedium?.copyWith(color: tvMuted),
                    ),
                    const SizedBox(height: 10),
                    if (channels.isEmpty) Text('No channels', style: text.bodyLarge),
                    Expanded(
                      child: ListView.builder(
                        itemCount: channels.length,
                        itemBuilder: (context, i) => _row(context, text, channels[i], sel, i == 0),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, TextTheme text, Channel c, Selection sel, bool first) {
    final shown = isShown(c, sel);
    final own = sel.channels[c.key]?.containsKey('on') ?? false;
    final name = withoutMarks(displayName(c, sel));
    final source = library.sourceById(widget.sourceId)!;
    final uid = '${widget.sourceId}:${c.key}';
    final guide = library.guideMatchText(uid);
    final moving = _moving == c.key;
    final parts = [
      if (c.number != null) '${c.number}',
      if (name != c.name) c.name,
      guide ?? (shown ? 'No guide' : ''),
    ].where((s) => s.isNotEmpty);
    return Padding(
      key: ValueKey(c.key),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: TvButton(
              autofocus: first,
              selected: shown || moving,
              onPressed: _moving != null
                  ? null
                  : () => library.change(widget.sourceId, [
                      {'channel': c.key, 'on': !shown},
                    ]),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(shown ? Icons.check_box : Icons.check_box_outline_blank, size: 22),
                  const SizedBox(width: 10),
                  ChannelLogo(url: c.logo, name: name, size: 32),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$name${own ? '  (own choice)' : ''}', overflow: TextOverflow.ellipsis),
                        Text(
                          parts.join('  -  '),
                          style: text.bodySmall?.copyWith(color: tvMuted),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (own) ...[
            const SizedBox(width: 6),
            TvButton(
              label: 'Follow group',
              onPressed: () => library.change(widget.sourceId, [
                {'channel': c.key, 'on': null},
              ]),
            ),
          ],
          const SizedBox(width: 6),
          TvButton(label: 'Rename', onPressed: () => _rename(c, name)),
          if (widget.groupId != null) ...[
            const SizedBox(width: 6),
            TvButton(
              label: moving ? 'Moving' : 'Move',
              selected: moving,
              onPressed: () => setState(() => _moving = c.key),
            ),
          ],
          const SizedBox(width: 6),
          TvButton(
            label: 'Guide',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => GuidePickPage(sourceId: widget.sourceId, channel: c),
              ),
            ),
          ),
          const SizedBox(width: 6),
          TvButton(
            label: 'Preview',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PreviewDialog(channel: PlayableChannel(source, c, name, '')),
            ),
          ),
        ],
      ),
    );
  }
}

/// Plays a channel in a box until Back or Close (the TV's player is stopped while Manage channels is open, so this is
/// still one connection).
class PreviewDialog extends StatefulWidget {
  const PreviewDialog({super.key, required this.channel});

  final PlayableChannel channel;

  @override
  State<PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<PreviewDialog> {
  VideoPlayerController? _player;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final address = await library.streamFor(widget.channel);
      final player = VideoPlayerController.networkUrl(
        Uri.parse(address.url),
        formatHint: address.hls ? VideoFormat.hls : null,
        httpHeaders: address.headers,
      );
      if (!mounted) return;
      setState(() => _player = player);
      await player.initialize().timeout(const Duration(seconds: 10));
      await player.play();
      if (mounted) setState(() {});
    } catch (err) {
      final why = await library.explainFailure(widget.channel, '$err');
      if (mounted) setState(() => _error = '${why.$1}. ${why.$2}');
    }
  }

  @override
  void dispose() {
    final p = _player;
    if (p != null) unawaited(p.pause().then((_) => p.dispose()));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    return AlertDialog(
      backgroundColor: tvSurface,
      title: Text(widget.channel.name),
      content: SizedBox(
        width: 480,
        height: 270,
        child: ColoredBox(
          color: Colors.black,
          child: _error != null
              ? Center(
                  child: Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
                )
              : p == null || !p.value.isInitialized
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: p.value.size.width == 0
                      ? const Icon(Icons.radio, size: 48, color: tvMuted)
                      : AspectRatio(aspectRatio: p.value.aspectRatio, child: VideoPlayer(p)),
                ),
        ),
      ),
      actions: [TvButton(label: 'Close', autofocus: true, onPressed: () => Navigator.of(context).pop())],
    );
  }
}
