/// Settings: Sources (what each holds; Manage channels, Refresh now, Edit, Remove; Add a source), Categories on the TV,
/// and the Guide (what each guide file holds, the free country files, Refresh guide now). A preset code typed here with
/// the number keys sets a source's channels (presets.dart).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/guide.dart';
import '../core/library.dart';
import '../core/presets.dart';
import '../core/sources.dart';
import 'add_source_page.dart';
import 'categories_page.dart';
import 'manage_source_page.dart';
import 'tv.dart';
import 'vpn_card.dart';

const appVersion = '0.7.3';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// The number keys pressed on this page, for a preset's code; shown as dots for a few seconds, so a press that went
  /// nowhere can be told from one that did.
  String _typed = '';
  Timer? _typedTimer;
  bool _noSuchCode = false;

  @override
  void dispose() {
    _typedTimer?.cancel();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // the remote's number keys (or a keyboard's): "1", or "Numpad 1" without a character
    final key = event.character ?? event.logicalKey.keyLabel.replaceFirst('Numpad ', '');
    if (event is! KeyDownEvent || !RegExp(r'^\d$').hasMatch(key)) return KeyEventResult.ignored;
    _typed = '$_typed$key';
    if (_typed.length > 16) _typed = _typed.substring(_typed.length - 16);
    _typedTimer?.cancel();
    _typedTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(_clearTyped);
    });
    setState(() => _noSuchCode = false);
    unawaited(_tryCode(_typed));
    return KeyEventResult.handled;
  }

  void _clearTyped() {
    _typed = '';
    _noSuchCode = false;
  }

  Future<void> _tryCode(String typed) async {
    final presets = await loadPresets();
    if (!mounted) return;
    final preset = presets.where((p) => typed.endsWith(p.code)).firstOrNull;
    if (preset == null) {
      // eight digits or more and nothing matches: say so (a slip of the finger, or a copy built without presets)
      if (typed.length >= 8) setState(() => _noSuchCode = true);
      return;
    }
    _typedTimer?.cancel();
    setState(_clearTyped);
    await _applyPreset(preset);
  }

  /// The preset's channels on its source; without that source yet, Add a source opens with its name and server, and
  /// the list is waited for once the login is saved. The viewer confirms before the ticks are replaced.
  Future<void> _applyPreset(Preset p) async {
    var source = presetSource(p, library.sources);
    if (source == null) {
      Source? added;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AddSourcePage(
            template: Source(id: '', kind: SourceKind.xtream, name: p.name, url: p.server ?? ''),
            onSaved: (s) => added = s,
          ),
        ),
      );
      source = added;
      if (source == null || !mounted) return;
    }
    final id = source.id;
    if (library.catalogs[id] == null) {
      final read = await _waitFor('Reading the channel list of ${source.name}...', library.whenListRead(id));
      if (!mounted) return;
      if (!read || library.catalogs[id] == null) {
        final why = library.statusOf(id).error;
        await _tell(
          source.name,
          'Its channel list could not be read${why == null ? '' : ': $why'}. '
          'Press Refresh now on its card, then type the code again.',
        );
        return;
      }
    }
    final result = applyPreset(library.catalogs[id]!, p, previous: library.selectionOf(id));
    if (result.shown == 0) {
      await _tell(
        'Nothing matched',
        'The preset names ${result.missing.join(', ')}, which the provider does not have now. '
            'The channels are left as they were.',
      );
      return;
    }
    final sel = result.selection;
    final categories = {for (final g in sel.groupOrder) (sel.groupNames[g] ?? g).toLowerCase()}.length;
    final yes = await _ask(
      'Set ${source.name} to the ${p.name} channels?',
      '${formatCount(result.shown)} channels in $categories categories replace the ticks on this login. '
          'Your own renames and guide picks are kept.'
          '${result.missing.isEmpty ? '' : '\n\nNot at the provider now: ${result.missing.join(', ')}.'}',
    );
    if (yes != true || !mounted) return;
    await library.setSelection(id, sel);
    if (!mounted) return;
    await _tell(
      '${source.name}: your channels are set',
      '${formatCount(result.shown)} channels in $categories categories.',
    );
  }

  /// A dialog with a spinner while [future] runs (up to 90 s); true when it finished in time.
  Future<bool> _waitFor(String message, Future<void> future) async {
    final nav = Navigator.of(context);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            backgroundColor: tvSurface,
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 16),
                Expanded(child: Text(message)),
              ],
            ),
          ),
        ),
      ),
    );
    var done = true;
    try {
      await future.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      done = false;
    }
    if (mounted) nav.pop();
    return done;
  }

  Future<bool?> _ask(String title, String body) => showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: tvSurface,
      title: Text(title),
      content: Text(body),
      actions: [
        TvButton(label: 'Cancel', autofocus: true, onPressed: () => Navigator.of(context).pop(false)),
        TvButton(label: 'Set them', onPressed: () => Navigator.of(context).pop(true)),
      ],
    ),
  );

  Future<void> _tell(String title, String body) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: tvSurface,
      title: Text(title),
      content: Text(body),
      actions: [TvButton(label: 'OK', autofocus: true, onPressed: () => Navigator.of(context).pop())],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final margin = overscanOf(context);
    return KeepAwake(
      child: ListenableBuilder(
        listenable: library,
        builder: (context, _) => Scaffold(
          backgroundColor: tvBackground,
          body: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onKey,
            child: Stack(
              children: [
                Padding(
                  padding: margin,
                  child: ListView(
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text('Settings', style: text.headlineSmall)),
                          TvButton(
                            label: 'Back to TV',
                            autofocus: library.sources.isEmpty,
                            onPressed: () => Navigator.of(context).pop(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text('Sources', style: text.titleMedium),
                      const SizedBox(height: 6),
                      for (final (i, s) in library.sources.indexed) _SourceCard(source: s, first: i == 0),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          TvButton(
                            label: 'Add a source',
                            onPressed: () =>
                                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AddSourcePage())),
                          ),
                          TvButton(
                            label: 'Categories on the TV',
                            onPressed: () =>
                                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CategoriesPage())),
                          ),
                          // the free channels every install starts with, back after a removal
                          if (!library.hasFreeTv)
                            TvButton(label: 'Add the free channels (Free-TV)', onPressed: library.addFreeTv),
                        ],
                      ),
                      const SizedBox(height: 24),
                      const _GuideCard(),
                      const SizedBox(height: 12),
                      const VpnCard(),
                      const SizedBox(height: 24),
                      Text('Nevermore IPTV $appVersion', style: text.bodySmall?.copyWith(color: tvMuted)),
                    ],
                  ),
                ),
                if (_typed.isNotEmpty)
                  Positioned(
                    right: margin.right,
                    bottom: margin.bottom,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(10)),
                        child: Text(
                          _noSuchCode ? '${'•' * _typed.length}   no preset has that code' : '•' * _typed.length,
                          style: text.bodyMedium,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GuideCard extends StatelessWidget {
  const _GuideCard();

  // its own listener: a const card is not rebuilt with the page, so a tick did not show (Mark, 24 Oct 2026: "I cannot
  // tick or untick the guides")
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: library, builder: (context, _) => _card(context));

  Widget _card(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final built = library.guideBuiltAt;
    final withGuide = library.programmes.values.where((p) => p.isNotEmpty).length;
    final shown = library.sources.fold<int>(0, (n, s) => n + library.shownCount(s.id));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Guide', style: text.titleMedium),
          const SizedBox(height: 4),
          Text(
            library.guideBusy
                ? 'Reading the guide...'
                : built == null
                ? 'Not read yet'
                : 'Read ${formatDate(built)} at ${formatTime(built)}: '
                      '${formatCount(withGuide)} of ${formatCount(shown)} shown channels have programmes',
            style: text.bodyMedium?.copyWith(color: tvMuted),
          ),
          const SizedBox(height: 6),
          for (final f in library.guideFiles)
            Text(
              '${f.label}: ${f.busy
                  ? 'downloading...'
                  : f.downloadedAt == null
                  ? 'not downloaded'
                  : '${(f.size / 1048576).toStringAsFixed(1)} MB, '
                        '${formatCount(f.channels)} channels, fetched ${formatDate(f.downloadedAt!)} ${formatTime(f.downloadedAt!)}'}'
              '${f.error == null ? '' : '  -  ${f.error}'}',
              style: (f.error == null ? text.bodySmall : text.bodyMedium)?.copyWith(
                color: f.error == null ? tvMuted : tvAlert,
              ),
            ),
          const SizedBox(height: 10),
          Text('Free guides from epgshare01 (they fill the gaps in a provider\'s guide):', style: text.bodySmall),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in epgCountries.entries)
                TvButton(
                  selected: library.epg.contains(e.key),
                  onPressed: () => library.setEpg(e.key, !library.epg.contains(e.key)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(library.epg.contains(e.key) ? Icons.check_box : Icons.check_box_outline_blank, size: 18),
                      const SizedBox(width: 6),
                      Text(e.value),
                    ],
                  ),
                ),
              // stays enabled while reading: a button that disables itself drops the focus to the top of the page
              TvButton(
                label: library.guideBusy ? 'Reading...' : 'Refresh guide now',
                onPressed: () {
                  if (!library.guideBusy) unawaited(library.refreshGuide(download: true));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.source, this.first = false});

  final Source source;

  /// The first card's Manage channels takes the focus when Settings opens.
  final bool first;

  List<String> _lines() {
    final st = library.statusOf(source.id);
    final cat = library.catalogs[source.id];
    final sel = library.selectionOf(source.id);
    final lines = <String>[];
    if (cat != null) {
      final ticked = cat.groups.where((g) => sel.groups[g.id] ?? false).length;
      lines.add(
        '${formatCount(library.shownCount(source.id))} of ${formatCount(cat.channels.length)} channels shown, '
        '$ticked of ${cat.groups.length} groups ticked'
        '${cat.skipped > 0 ? ', ${formatCount(cat.skipped)} skipped as unplayable' : ''}',
      );
    }
    final account = st.account;
    if (account != null) lines.add(accountLine(account));
    if (st.busy) {
      lines.add('Reading the channel list...');
    } else if (st.readAt != null) {
      lines.add(
        'List read ${formatDate(st.readAt!)} at ${formatTime(st.readAt!)}'
        '${source.isXtream ? ' - streams as ${source.output == 'ts' ? 'TS' : 'HLS'}' : ''}',
      );
    }
    if (st.error != null) lines.add('Last read failed: ${st.error}');
    return lines;
  }

  Future<void> _remove(BuildContext context) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: tvSurface,
        title: Text('Remove ${source.name}?'),
        content: const Text('Its login, channel list, guide download and ticks are removed from this TV.'),
        actions: [
          TvButton(label: 'Cancel', autofocus: true, onPressed: () => Navigator.of(context).pop(false)),
          TvButton(label: 'Remove', onPressed: () => Navigator.of(context).pop(true)),
        ],
      ),
    );
    if (yes == true) await library.removeSource(source.id);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${source.name}  -  ${source.isXtream ? 'Xtream Codes login' : 'M3U link'}', style: text.titleMedium),
          const SizedBox(height: 4),
          // 14sp, not 12: these lines are read from the sofa
          for (final line in _lines())
            Text(
              line,
              style: text.bodyMedium?.copyWith(color: line.startsWith('Last read failed') ? tvAlert : tvMuted),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              TvButton(
                label: 'Manage channels',
                autofocus: first,
                onPressed: () =>
                    Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => ManageSourcePage(sourceId: source.id))),
              ),
              TvButton(label: 'Refresh now', onPressed: () => library.refresh(source)),
              TvButton(
                label: 'Edit',
                onPressed: () =>
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddSourcePage(existing: source))),
              ),
              TvButton(label: 'Remove', onPressed: () => _remove(context)),
            ],
          ),
        ],
      ),
    );
  }
}
