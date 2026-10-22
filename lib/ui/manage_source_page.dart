/// Manage channels for one source: every group with a tick and shown/total, its channels, a rename; and a search
/// across the source's channels. OK on a group ticks or unticks it; a channel the provider adds to a ticked group shows
/// by itself.
library;

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/model.dart';
import 'manage_channels_page.dart';
import 'tv.dart';

class ManageSourcePage extends StatelessWidget {
  const ManageSourcePage({super.key, required this.sourceId, this.firstTime = false, this.onDone});

  final String sourceId;
  final bool firstTime;
  final VoidCallback? onDone;

  Future<void> _search(BuildContext context) async {
    final nav = Navigator.of(context);
    final query = await nav.push<String>(
      MaterialPageRoute(
        builder: (_) => const TextEntryPage(label: 'Search channels', initial: '', hint: 'Part of a name or a number'),
      ),
    );
    if (query == null || query.trim().isEmpty) return;
    final found = library.searchChannels(sourceId, query);
    await nav.push(
      MaterialPageRoute(
        builder: (_) => ManageChannelsPage(
          sourceId: sourceId,
          keys: [for (final c in found) c.key],
          title: '"${query.trim()}": ${found.length}${found.length >= 200 ? '+' : ''} channels',
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, Group g, String shown) async {
    final name = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) =>
            TextEntryPage(label: 'Rename ${g.name}', initial: shown, hint: 'Leave it empty for the provider\'s name'),
      ),
    );
    if (name != null) {
      await library.change(sourceId, [
        {'group': g.id, 'name': name},
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final source = library.sourceById(sourceId);
        final catalog = library.catalogs[sourceId];
        final st = library.statusOf(sourceId);
        final sel = library.selectionOf(sourceId);
        final groups = catalog == null ? const <Group>[] : orderedGroups(catalog, sel);
        final total = <String, int>{};
        final shown = <String, int>{};
        for (final c in catalog?.channels ?? const <Channel>[]) {
          total[c.group] = (total[c.group] ?? 0) + 1;
          if (isShown(c, sel)) shown[c.group] = (shown[c.group] ?? 0) + 1;
        }
        final done = onDone ?? () => Navigator.of(context).pop();
        return Scaffold(
          backgroundColor: tvBackground,
          body: Padding(
            padding: overscan,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text('Manage channels - ${source?.name ?? ''}', style: text.headlineSmall)),
                    if (catalog != null) ...[
                      TvButton(label: 'Search channels', onPressed: () => _search(context)),
                      const SizedBox(width: 10),
                    ],
                    TvButton(label: 'Done', onPressed: done),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  firstTime
                      ? 'Tick the groups to show on this TV. You can change them later in Settings.'
                      : 'OK ticks or unticks a group. Channels: tick single channels, rename, move, pick their guide.',
                  style: text.bodyMedium?.copyWith(color: tvMuted),
                ),
                const SizedBox(height: 12),
                if (catalog == null)
                  Text(
                    st.busy ? 'Reading the channel list...' : (st.error ?? 'No channel list yet.'),
                    style: text.bodyLarge,
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: groups.length,
                    itemBuilder: (context, i) {
                      final g = groups[i];
                      final on = sel.groups[g.id] ?? false;
                      final name = withoutMarks(groupName(g, sel));
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: TvButton(
                                autofocus: i == 0,
                                selected: on,
                                onPressed: () => library.setGroup(sourceId, g.id, !on),
                                child: Row(
                                  children: [
                                    Icon(on ? Icons.check_box : Icons.check_box_outline_blank, size: 22),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        name == g.name ? name : '$name  (${g.name})',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text('${shown[g.id] ?? 0} of ${total[g.id] ?? 0}'),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TvButton(
                              label: 'Channels',
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => ManageChannelsPage(sourceId: sourceId, groupId: g.id),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            TvButton(label: 'Rename', onPressed: () => _rename(context, g, name)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
