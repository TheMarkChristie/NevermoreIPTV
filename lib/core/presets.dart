/// Presets: a code typed with the remote's number keys on Settings sets a source's channels in one go (Mark, 24 Oct
/// 2026: "when on the menu screen I want to be able to type [a code] and it will install my default settings").
///
/// The presets are not in the code. They come from `assets/house/presets.json`, which stays out of the repository (it
/// names one household's provider and picks); without it the codes do nothing.
///
///     {"presets": [{"code": "12345678", "name": "My provider", "server": "http://host:8080",
///                   "groups": [{"group": "UK-SPORTS", "name": "UK Sport", "all": true},
///                              {"group": "NHL", "channels": ["nhl network", "seattle kraken"]}]}]}
///
/// A group is found by its provider name (any case). "all" ticks the whole group, so channels the provider adds show
/// by themselves; "channels" ticks each channel of the group whose name holds one of the words; "name" renames the
/// group on the TV (two groups given one name make one category); "guides" names epgshare01 files to tick.
///
/// A preset may carry its login, locked with the code (preset_lock.dart): then "code" is not in the file, "lock" is,
/// and the preset is found by the code opening it; the source is added from the login when the TV lacks it. Without a
/// login the source must be on the TV, or is asked for with the server filled in.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'guide.dart';
import 'library.dart';
import 'model.dart';
import 'preset_lock.dart';
import 'sources.dart';
import 'xtream.dart';

class PresetGroup {
  const PresetGroup(this.group, {this.name, this.all = false, this.channels = const []});

  final String group;
  final String? name;
  final bool all;

  /// Lower case.
  final List<String> channels;

  factory PresetGroup.fromJson(Map<String, dynamic> j) {
    final name = '${j['name'] ?? ''}'.trim();
    return PresetGroup(
      '${j['group'] ?? ''}'.trim(),
      name: name.isEmpty ? null : name,
      all: j['all'] == true,
      channels: [
        for (final c in (j['channels'] as List? ?? const []))
          if ('$c'.trim().isNotEmpty) '$c'.trim().toLowerCase(),
      ],
    );
  }
}

class Preset {
  const Preset({this.code, required this.name, this.server, this.groups = const [], this.guides = const [], this.lock});

  /// The code, when the file has it plain; a locked preset has none written down (the code is its key).
  final String? code;

  /// The login locked with the code, when the file carries one.
  final PresetLock? lock;

  /// The source's name when the TV has to add it.
  final String name;

  /// "http://host:8080": the Xtream server the picks are for.
  final String? server;
  final List<PresetGroup> groups;

  /// epgshare01 files to tick with the picks (codes of [epgFiles]: "US", "CA"); the picks' guide comes with them.
  final List<String> guides;

  factory Preset.fromJson(Map<String, dynamic> j) {
    final server = '${j['server'] ?? ''}'.trim();
    final code = '${j['code'] ?? ''}'.trim();
    return Preset(
      code: code.isEmpty ? null : code,
      lock: PresetLock.fromJson(j['lock']),
      name: '${j['name'] ?? ''}'.trim(),
      server: server.isEmpty ? null : normalAddress(server),
      groups: [
        for (final g in (j['groups'] as List? ?? const []))
          if (g is Map) PresetGroup.fromJson(Map<String, dynamic>.from(g)),
      ],
      guides: [for (final g in (j['guides'] as List? ?? const [])) '$g'.trim().toUpperCase()],
    );
  }
}

/// The presets in a presets.json; anything unreadable is left out.
List<Preset> presetsFromJson(Object? data) => [
  if (data is Map)
    for (final p in (data['presets'] as List? ?? const []))
      if (p is Map) Preset.fromJson(Map<String, dynamic>.from(p)),
].where((p) => p.code != null || p.lock != null).toList();

/// A site for the guide's Web category: the same file's "sites": [{"name": "Club TV", "url": "https://..."}].
class WebSite {
  const WebSite(this.name, this.url);

  final String name;
  final String url;
}

/// The sites in a presets.json; one without an http(s) address is left out, one without a name is called by its host.
List<WebSite> sitesFromJson(Object? data) => [
  if (data is Map)
    for (final s in (data['sites'] as List? ?? const []))
      if (s is Map && Uri.tryParse('${s['url'] ?? ''}'.trim())?.scheme.startsWith('http') == true)
        WebSite(
          '${s['name'] ?? ''}'.trim().isEmpty ? Uri.parse('${s['url']}'.trim()).host : '${s['name']}'.trim(),
          '${s['url']}'.trim(),
        ),
];

Future<Object?>? _houseMemo;

/// The house file: the one built into this copy, kept in the app's own folder once seen, so a copy built without it
/// (a public build installed over this one) does not take the household's preset and sites away (review, 24 Oct 2026).
Future<Object?> _houseFile() => _houseMemo ??= _readHouseFile();

Future<Object?> _readHouseFile() async {
  File? kept;
  try {
    kept = File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}presets.json');
  } catch (_) {
    // no folder (a test): the bundled file alone
  }
  try {
    final text = await rootBundle.loadString('assets/house/presets.json');
    final data = jsonDecode(text);
    if (kept != null && (!await kept.exists() || await kept.readAsString() != text)) {
      await kept.writeAsString(text, flush: true);
    }
    return data;
  } catch (_) {
    // not built in: the copy kept earlier, if any
  }
  try {
    if (kept != null && await kept.exists()) return jsonDecode(await kept.readAsString());
  } catch (_) {
    // unreadable
  }
  return null;
}

/// The presets built into this copy of the app; none when it was built without the file.
Future<List<Preset>> loadPresets() async => presetsFromJson(await _houseFile());

/// The web sites built into this copy of the app; none without the file.
Future<List<WebSite>> loadSites() async => sitesFromJson(await _houseFile());

/// The preset a code opens, with its login when it carries one: a plain code is matched outright, a locked preset by
/// the code unlocking it (slow on purpose, a second or more each). Null when no preset answers to the code.
Future<(Preset, PresetLogin?)?> presetForCode(List<Preset> presets, String code) async {
  final typed = code.trim();
  if (typed.isEmpty) return null;
  for (final p in presets) {
    if (p.code != null && p.code == typed) return (p, null);
  }
  for (final p in presets) {
    final lock = p.lock;
    if (lock == null || lock.length != typed.length) continue;
    final login = await unlockPreset(lock, typed);
    if (login != null) return (p, login);
  }
  return null;
}

/// The preset's source, added from the login that came with its code: checked with the provider (an XtreamError says
/// why not), then saved with its channel list.
Future<Source> addPresetSource(Library lib, Preset p, PresetLogin login) async {
  final source = Source(
    id: Source.newId(),
    kind: SourceKind.xtream,
    name: p.name,
    url: normalAddress(p.server ?? ''),
    username: login.username,
    password: login.password,
  );
  final result = await lib.check(source);
  await lib.saveSource(source, catalog: result.catalog, account: result.account);
  return source;
}

/// The preset's source on this TV: the Xtream login on its server, else the Xtream source with its name.
Source? presetSource(Preset p, List<Source> sources) {
  final xtream = sources.where((s) => s.isXtream);
  final host = p.server == null ? null : Uri.tryParse(p.server!)?.host.toLowerCase();
  if (host != null && host.isNotEmpty) {
    final onServer = xtream.where((s) => Uri.tryParse(s.url)?.host.toLowerCase() == host).firstOrNull;
    if (onServer != null) return onServer;
  }
  return xtream.where((s) => s.name.toLowerCase() == p.name.toLowerCase()).firstOrNull;
}

class PresetResult {
  PresetResult(this.selection, this.shown, this.missing);

  final Selection selection;

  /// Channels it shows.
  final int shown;

  /// What the preset names that the provider does not have now ("NHL: seattle kraken", "PPV-3").
  final List<String> missing;
}

/// A preset code handed in by the install script (`-Preset`): applied to its source when the TV has it, once that
/// source's list is read. Returns a line for the notice on the TV ("preset My provider: 242 channels"), or why not.
Future<String> applyPresetCode(Library lib, String code) async {
  final found = await presetForCode(await loadPresets(), code);
  if (found == null) return 'no preset has that code';
  final (p, login) = found;
  var source = presetSource(p, lib.sources);
  if (source == null) {
    if (login == null) return 'preset ${p.name}: its login is not on this TV';
    try {
      source = await addPresetSource(lib, p, login);
    } on XtreamError catch (err) {
      return 'preset ${p.name}: the login was refused: ${err.message}';
    } catch (err) {
      return 'preset ${p.name}: the login could not be checked: $err';
    }
  }
  await lib.whenListRead(source.id).timeout(const Duration(seconds: 90), onTimeout: () {});
  final catalog = lib.catalogs[source.id];
  if (catalog == null) return 'preset ${p.name}: the channel list could not be read';
  final result = applyPreset(catalog, p, previous: lib.selectionOf(source.id));
  if (result.shown == 0) return 'preset ${p.name}: nothing matched, channels left as they were';
  await lib.setSelection(source.id, result.selection);
  await tickPresetGuides(lib, p);
  return 'preset ${p.name}: ${result.shown} channels';
}

/// The guide files a preset names, ticked (never unticked: a viewer's own ticks stay).
Future<void> tickPresetGuides(Library lib, Preset p) async {
  for (final code in p.guides) {
    if (epgFiles.containsKey(code) && !lib.epg.contains(code)) await lib.setEpg(code, true);
  }
}

/// The source's new selection: what the preset names, in its order. The viewer's own renames, hand-picked guides and
/// channel order from [previous] are kept (review, 24 Oct 2026); the ticks are the preset's alone.
PresetResult applyPreset(Catalog catalog, Preset p, {Selection? previous}) {
  final sel = Selection(channelOrder: previous == null ? null : List.of(previous.channelOrder));
  if (previous != null) {
    for (final e in previous.channels.entries) {
      final own = {
        for (final k in const ['name', 'guide'])
          if (e.value[k] != null) k: e.value[k]!,
      };
      if (own.isNotEmpty) sel.channels[e.key] = own;
    }
  }
  final missing = <String>[];
  for (final pg in p.groups) {
    final wanted = pg.group.toLowerCase();
    final g = catalog.groups.where((g) => g.name.trim().toLowerCase() == wanted).firstOrNull;
    if (g == null) {
      missing.add(pg.group);
      continue;
    }
    if (!sel.groupOrder.contains(g.id)) sel.groupOrder.add(g.id);
    if (pg.name != null) sel.groupNames[g.id] = pg.name!;
    if (pg.all) {
      sel.groups[g.id] = true;
      continue;
    }
    final inGroup = [
      for (final c in catalog.channels)
        if (c.group == g.id) c,
    ];
    for (final word in pg.channels) {
      final hits = inGroup.where((c) => c.name.toLowerCase().contains(word)).toList();
      if (hits.isEmpty) missing.add('${pg.group}: $word');
      for (final c in hits) {
        sel.channels[c.key] = {...?sel.channels[c.key], 'on': true};
      }
    }
  }
  return PresetResult(sel, shownChannels(catalog, sel).length, missing);
}
