/// Categories on the TV: every category the guide shows, in its order, with Rename and Move. Groups from different
/// sources with the same name are one category; renaming one to another's name joins them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/library.dart';
import 'tv.dart';

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});

  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  List<Category>? _moving;
  String? _movingName;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final list = _moving;
    final name = _movingName;
    if (list == null || name == null || event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final at = list.indexWhere((c) => c.name == name);
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final to = at + (k == LogicalKeyboardKey.arrowUp ? -1 : 1);
      if (at >= 0 && to >= 0 && to < list.length) {
        setState(() => list.insert(to, list.removeAt(at)));
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
    final list = _moving;
    if (list == null) return;
    setState(() {
      _moving = null;
      _movingName = null;
    });
    await library.saveCategoryOrder(list);
  }

  Future<void> _rename(Category c) async {
    final name = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => TextEntryPage(
          label: 'Rename ${c.name}',
          initial: c.name,
          hint: 'Leave it empty for the providers\' names. A name another category has joins the two.',
        ),
      ),
    );
    if (name != null) await library.renameCategory(c, name);
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
          final categories = _moving ?? library.categories();
          return Scaffold(
            backgroundColor: tvBackground,
            body: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: Padding(
                padding: overscan,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('Categories on the TV', style: text.headlineSmall)),
                        TvButton(label: 'Done', onPressed: () => Navigator.of(context).maybePop()),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _moving != null
                          ? 'Up / Down move the category. OK puts it down.'
                          : 'The guide\'s categories, in this order. Tick groups in each source\'s Manage channels.',
                      style: text.bodyMedium?.copyWith(color: tvMuted),
                    ),
                    const SizedBox(height: 10),
                    if (categories.isEmpty) Text('No groups ticked yet.', style: text.bodyLarge),
                    Expanded(
                      child: ListView.builder(
                        itemCount: categories.length,
                        itemBuilder: (context, i) {
                          final c = categories[i];
                          final moving = _movingName == c.name;
                          final from = {for (final ch in c.channels) ch.source.name}.join(', ');
                          return Padding(
                            key: ValueKey(c.name),
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TvButton(
                                    autofocus: i == 0,
                                    selected: moving,
                                    onPressed: null,
                                    child: Row(
                                      children: [
                                        Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                                        Text(
                                          '${c.channels.length} channels  -  $from',
                                          style: text.bodySmall?.copyWith(color: tvMuted),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                TvButton(label: 'Rename', onPressed: _moving != null ? null : () => _rename(c)),
                                const SizedBox(width: 8),
                                TvButton(
                                  label: moving ? 'Moving' : 'Move',
                                  selected: moving,
                                  autofocus: i == 0,
                                  onPressed: () => setState(() {
                                    _moving = List.of(library.categories());
                                    _movingName = c.name;
                                  }),
                                ),
                              ],
                            ),
                          );
                        },
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
}
