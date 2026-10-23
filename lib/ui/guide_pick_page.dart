/// A channel's guide: what it is matched to now, Automatic (the guide id, else the name), or a guide channel picked by
/// hand from a search across every guide file.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/model.dart';
import 'tv.dart';

class GuidePickPage extends StatefulWidget {
  const GuidePickPage({super.key, required this.sourceId, required this.channel});

  final String sourceId;
  final Channel channel;

  @override
  State<GuidePickPage> createState() => _GuidePickPageState();
}

class _GuidePickPageState extends State<GuidePickPage> {
  late String _query = tidyName(displayName(widget.channel, library.selectionOf(widget.sourceId)));
  List<({String source, int sourceIndex, String id, String name})>? _found;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_search());
  }

  Future<void> _search() async {
    setState(() => _busy = true);
    final found = await library.searchGuide(_query);
    if (mounted) {
      setState(() {
        _found = found;
        _busy = false;
      });
    }
  }

  Future<void> _set(String? guide) async {
    await library.change(widget.sourceId, [
      {'channel': widget.channel.key, 'guide': guide},
    ]);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sel = library.selectionOf(widget.sourceId);
    final manual = '${sel.channels[widget.channel.key]?['guide'] ?? ''}';
    final current = library.guideMatchText('${widget.sourceId}:${widget.channel.key}');
    final found = _found;
    return Scaffold(
      backgroundColor: tvBackground,
      body: Padding(
        padding: overscanOf(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Guide for ${withoutMarks(displayName(widget.channel, sel))}',
                    style: text.headlineSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TvButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Now: ${current ?? 'no guide'}${manual.isNotEmpty ? '' : '  (automatic)'}',
              style: text.bodyMedium?.copyWith(color: tvMuted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TvButton(
                  label: 'Search: $_query',
                  autofocus: true,
                  onPressed: () async {
                    final q = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => TextEntryPage(label: 'Search the guide', initial: _query),
                      ),
                    );
                    if (q != null && q.trim().isNotEmpty) {
                      setState(() => _query = q.trim());
                      await _search();
                    }
                  },
                ),
                const SizedBox(width: 10),
                TvButton(label: 'Automatic', selected: manual.isEmpty, onPressed: () => _set(null)),
              ],
            ),
            const SizedBox(height: 12),
            if (_busy) const LinearProgressIndicator(),
            if (found != null && found.isEmpty && !_busy)
              Text('No guide channel has those words. Try fewer, or another spelling.', style: text.bodyMedium),
            Expanded(
              child: ListView.builder(
                itemCount: found?.length ?? 0,
                itemBuilder: (context, i) {
                  final f = found![i];
                  final pick = '${f.source}|${f.id}';
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: TvButton(
                      selected: pick == manual,
                      onPressed: () => _set(pick),
                      child: Row(
                        children: [
                          Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis)),
                          Text('${f.id}  -  ${f.source}', style: text.bodySmall?.copyWith(color: tvMuted)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Text(
              'The guide is read again a few seconds after a change.',
              style: text.bodySmall?.copyWith(color: tvMuted),
            ),
          ],
        ),
      ),
    );
  }
}
