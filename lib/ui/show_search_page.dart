/// Search the guide for a show: the shows matching the words, title matches first, soonest first. OK on one on now
/// watches it; on a later one, the guide opens at it.
library;

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/model.dart';
import '../core/show_search.dart';
import 'tv.dart';

/// What was picked: the channel and the programme.
typedef ShowPick = (PlayableChannel, Programme);

/// Asks for the words, then shows what matches. Returns the pick, or null.
Future<ShowPick?> searchForShow(BuildContext context, {String initial = ''}) async {
  final nav = Navigator.of(context);
  final query = await nav.push<String>(
    MaterialPageRoute(
      builder: (_) => TextEntryPage(
        label: 'Search the guide for a show',
        initial: initial,
        hint: 'Part of a title, for example "news" or "walker texas"',
      ),
    ),
  );
  if (query == null || query.trim().isEmpty) return null;
  return nav.push<ShowPick>(MaterialPageRoute(builder: (_) => ShowSearchPage(query: query.trim())));
}

class ShowSearchPage extends StatelessWidget {
  const ShowSearchPage({super.key, required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final hits = library.findShows(query);
    final now = nowSeconds();
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
                  child: Text('Shows matching "$query"', style: text.headlineSmall, overflow: TextOverflow.ellipsis),
                ),
                TvButton(
                  label: 'Search again',
                  autofocus: hits.isEmpty,
                  onPressed: () async {
                    final nav = Navigator.of(context);
                    final pick = await searchForShow(context, initial: query);
                    if (pick != null) nav.pop(pick);
                  },
                ),
                const SizedBox(width: 10),
                TvButton(label: 'Close', onPressed: () => Navigator.of(context).pop()),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              hits.isEmpty
                  ? 'No show in the guide has those words. The guide covers the channels shown on this TV, '
                        'from now to 36 hours ahead.'
                  : '${hits.length}${hits.length >= 100 ? '+' : ''} found. OK on a show on now watches it; '
                        'on a later one, the guide opens at it.',
              style: text.bodyMedium?.copyWith(color: tvMuted),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: hits.length,
                itemBuilder: (context, i) {
                  final (ch, hit) = hits[i];
                  final p = hit.programme;
                  final onNow = p.start <= now && now < p.stop;
                  final extra = [p.sub, p.category].where((s) => s.isNotEmpty).join('  -  ');
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: TvButton(
                      autofocus: i == 0,
                      selected: onNow,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      onPressed: () => Navigator.of(context).pop<ShowPick>((ch, p)),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 140,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  onNow ? 'On now' : dayAndTime(p.start, now),
                                  style: onNow ? const TextStyle(fontWeight: FontWeight.w700) : null,
                                ),
                                if (onNow)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4, right: 20),
                                    child: ProgressLine(value: progressOf(p, now)),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(p.title, overflow: TextOverflow.ellipsis),
                                if (extra.isNotEmpty)
                                  Text(
                                    extra,
                                    style: text.bodySmall?.copyWith(color: tvMuted),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          ChannelLogo(url: ch.channel.logo, name: ch.name, size: 32),
                          const SizedBox(width: 8),
                          SizedBox(width: 200, child: Text(ch.name, overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
