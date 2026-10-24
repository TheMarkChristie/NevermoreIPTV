/// The channel catalogue, the selection and the guide matching. Pure Dart, tested on its own (port of the IPTV
/// Player's model.py).
///
/// A catalogue is one source's groups and live channels. The selection is what was ticked on this TV:
///
///     groups:        {group id: true}                          ticked groups
///     channels:      {channel key: {on, name, guide}}          per-channel choices, each optional
///     group_order:   [group id]    channel_order: [channel key]
///     group_names:   {group id: name}
///
/// A channel shows when its own "on" says so, else when its group is ticked: a channel the provider adds to a ticked
/// group shows by itself, and one that was unticked stays hidden.
library;

import 'm3u.dart';

const unplayableHosts = ['youtube.com', 'youtu.be', 'twitch.tv', 'dailymotion.com', 'facebook.com'];

class Group {
  const Group(this.id, this.name, this.order);

  final String id;
  final String name;
  final int order;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'order': order};

  factory Group.fromJson(Map<String, dynamic> j) => Group('${j['id']}', '${j['name']}', (j['order'] as num).toInt());
}

class Channel {
  const Channel(
    this.key,
    this.name,
    this.group,
    this.order, {
    this.logo,
    this.guideId,
    this.number,
    this.url,
    this.streamId,
    this.userAgent,
    this.referrer,
    this.radio = false,
    this.country,
  });

  /// Stable inside its source: the Xtream stream id, or the playlist's group + name.
  final String key;
  final String name;

  /// [Group.id].
  final String group;

  /// The provider's order.
  final int order;
  final String? logo;

  /// tvg-id / epg_channel_id.
  final String? guideId;
  final int? number;

  /// M3U: the stream address. Xtream: null (built from the stream id when played).
  final String? url;
  final String? streamId;

  /// From the playlist's #EXTVLCOPT.
  final String? userAgent;
  final String? referrer;

  /// Xtream's stream_type "radio_streams" (a provider that says so).
  final bool radio;

  /// The country the channel belongs to (ISO code, "DK"), when its playlist, name or group says: see [countryHint].
  final String? country;

  Map<String, dynamic> toJson() => {
    'key': key,
    'name': name,
    'group': group,
    'order': order,
    'logo': ?logo,
    'guide_id': ?guideId,
    'number': ?number,
    'url': ?url,
    'stream_id': ?streamId,
    'user_agent': ?userAgent,
    'referrer': ?referrer,
    if (radio) 'radio': true,
    'country': ?country,
  };

  factory Channel.fromJson(Map<String, dynamic> j) => Channel(
    '${j['key']}',
    '${j['name']}',
    '${j['group']}',
    (j['order'] as num).toInt(),
    logo: j['logo'] as String?,
    guideId: j['guide_id'] as String?,
    number: (j['number'] as num?)?.toInt(),
    url: j['url'] as String?,
    streamId: j['stream_id'] as String?,
    userAgent: j['user_agent'] as String?,
    referrer: j['referrer'] as String?,
    radio: j['radio'] == true,
    country: j['country'] as String?,
  );
}

class Catalog {
  Catalog({List<Group>? groups, List<Channel>? channels, this.skipped = 0, List<String>? guideUrls})
    : groups = groups ?? [],
      channels = channels ?? [],
      guideUrls = guideUrls ?? [];

  final List<Group> groups;
  final List<Channel> channels;

  /// Entries that cannot play here (YouTube, Twitch, DASH).
  final int skipped;

  /// Guides the playlist names in its header.
  final List<String> guideUrls;

  Group? group(String id) => groups.where((g) => g.id == id).firstOrNull;

  Channel? channel(String key) => channels.where((c) => c.key == key).firstOrNull;

  Map<String, dynamic> toJson() => {
    'groups': [for (final g in groups) g.toJson()],
    'channels': [for (final c in channels) c.toJson()],
    'skipped': skipped,
    'guide_urls': guideUrls,
  };

  factory Catalog.fromJson(Map<String, dynamic> j) => Catalog(
    groups: [for (final g in (j['groups'] as List? ?? const [])) Group.fromJson(Map<String, dynamic>.from(g as Map))],
    channels: [
      for (final c in (j['channels'] as List? ?? const [])) Channel.fromJson(Map<String, dynamic>.from(c as Map)),
    ],
    skipped: (j['skipped'] as num?)?.toInt() ?? 0,
    guideUrls: [for (final u in (j['guide_urls'] as List? ?? const [])) '$u'],
  );
}

// ---- building a catalogue ---------------------------------------------------------------------------------------------

String _str(Object? value) => value == null ? '' : '$value';

String? _blank(Object? value) {
  final t = _str(value).trim();
  return t.isEmpty ? null : t;
}

int? _int(Object? value) => int.tryParse(_str(value).trim());

/// player_api.php's get_live_categories + get_live_streams.
Catalog catalogFromXtream(List<Map<String, dynamic>> categories, List<Map<String, dynamic>> streams) {
  final groups = <Group>[
    for (var i = 0; i < categories.length; i++)
      Group(
        _str(categories[i]['category_id']),
        _blank(categories[i]['category_name']) ?? _str(categories[i]['category_id']),
        i,
      ),
  ];
  final known = {for (final g in groups) g.id};
  final channels = <Channel>[];
  for (var i = 0; i < streams.length; i++) {
    final s = streams[i];
    final type = _blank(s['stream_type']) ?? 'live';
    if (!const {'live', 'created_live', 'radio_streams'}.contains(type)) continue;
    final sid = _str(s['stream_id']).trim();
    if (sid.isEmpty) continue;
    var gid = _str(s['category_id']);
    if (!known.contains(gid)) gid = '_other';
    final name = _blank(s['name']) ?? sid;
    channels.add(
      Channel(
        sid,
        name,
        gid,
        i,
        logo: _blank(s['stream_icon']),
        guideId: _blank(s['epg_channel_id']),
        number: _int(s['num']),
        streamId: sid,
        radio: type == 'radio_streams',
        country: countryHint(name: name),
      ),
    );
  }
  if (channels.any((c) => c.group == '_other')) groups.add(Group('_other', 'Other', groups.length));
  return Catalog(groups: groups, channels: channels);
}

bool playableUrl(String url) {
  final low = url.toLowerCase();
  if (!low.startsWith('http://') && !low.startsWith('https://')) return false;
  final parts = low.split('/');
  final host = parts.length > 2 ? parts[2].split(':').first : '';
  if (unplayableHosts.any((h) => host == h || host.endsWith('.$h'))) return false;
  // DASH needs another player route; not in this version
  return !low.split('?').first.endsWith('.mpd');
}

const _fold = {
  'à': 'a',
  'á': 'a',
  'â': 'a',
  'ã': 'a',
  'ä': 'a',
  'å': 'a',
  'æ': 'ae',
  'ç': 'c',
  'è': 'e',
  'é': 'e',
  'ê': 'e',
  'ë': 'e',
  'ì': 'i',
  'í': 'i',
  'î': 'i',
  'ï': 'i',
  'ð': 'd',
  'ñ': 'n',
  'ò': 'o',
  'ó': 'o',
  'ô': 'o',
  'õ': 'o',
  'ö': 'o',
  'ø': 'o',
  'ù': 'u',
  'ú': 'u',
  'û': 'u',
  'ü': 'u',
  'ý': 'y',
  'ÿ': 'y',
  'þ': 'th',
  'ß': 'ss',
  'œ': 'oe',
  'ł': 'l',
  'ś': 's',
  'š': 's',
  'ž': 'z',
  'ź': 'z',
  'ż': 'z',
  'č': 'c',
  'ć': 'c',
  'ř': 'r',
  'ě': 'e',
  'ů': 'u',
};

/// Lower case, accented letters as their plain ones (å -> a, ø -> o), anything else outside ASCII dropped.
String foldAscii(String text) {
  final out = StringBuffer();
  for (final rune in text.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    if (rune < 128) {
      out.write(ch);
    } else if (_fold[ch] != null) {
      out.write(_fold[ch]);
    }
  }
  return out.toString();
}

String _slug(String text) => foldAscii(text).replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');

/// A short hash that is the same on every start (FNV-1a, 32 bits, as hex), for keys that must survive restarts.
String stableHash(String text) {
  var h = 0x811c9dc5;
  for (final unit in text.codeUnits) {
    h = ((h ^ unit) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}

Catalog catalogFromM3u(Iterable<M3uEntry> entries, [List<String>? headerGuideUrls]) {
  final list = entries.toList();
  final groups = <String, Group>{};
  final channels = <Channel>[];
  // how many entries share each group + name: a name keys a channel only when it is the only one of its kind
  final shared = <String, int>{};
  for (final e in list) {
    if (!playableUrl(e.url)) continue;
    final base = '${_slug(e.group ?? 'Other')}/${_slug(tidyName(e.name))}';
    shared[base] = (shared[base] ?? 0) + 1;
  }
  final usedKeys = <String>{};
  var skipped = 0;
  var i = -1;
  for (final e in list) {
    i++;
    if (!playableUrl(e.url)) {
      skipped++;
      continue;
    }
    final gname = e.group ?? 'Other';
    groups.putIfAbsent(gname, () => Group(gname, gname, groups.length));
    final slug = _slug(tidyName(e.name));
    final base = '${_slug(gname)}/$slug';
    // the plain key where the name is the only one of its kind, so earlier ticks survive; a name that folds to nothing,
    // or one shared with another entry, is keyed by its address, which stays put when the playlist is reordered
    // (review, 24 Oct 2026)
    var key = slug.isNotEmpty && shared[base] == 1
        ? base
        : '${_slug(gname)}/${slug.isEmpty ? 'x' : slug}~${stableHash(e.url)}';
    while (!usedKeys.add(key)) {
      key = '$key~';
    }
    channels.add(
      Channel(
        key,
        e.name,
        gname,
        i,
        logo: e.logo,
        guideId: e.tvgId,
        number: _int(e.chno),
        url: e.url,
        userAgent: e.userAgent,
        referrer: e.referrer,
        country: countryHint(name: e.name, tvgCountry: e.country, group: gname),
      ),
    );
  }
  return Catalog(
    groups: groups.values.toList(),
    channels: channels,
    skipped: skipped,
    guideUrls: [...?headerGuideUrls],
  );
}

// ---- the selection ----------------------------------------------------------------------------------------------------

class Selection {
  Selection({
    Map<String, bool>? groups,
    Map<String, Map<String, Object>>? channels,
    List<String>? groupOrder,
    List<String>? channelOrder,
    Map<String, String>? groupNames,
  }) : groups = groups ?? {},
       channels = channels ?? {},
       groupOrder = groupOrder ?? [],
       channelOrder = channelOrder ?? [],
       groupNames = groupNames ?? {};

  final Map<String, bool> groups;
  final Map<String, Map<String, Object>> channels;
  final List<String> groupOrder;
  final List<String> channelOrder;
  final Map<String, String> groupNames;

  /// A selection from stored JSON, tolerating anything missing (normal_selection).
  factory Selection.fromJson(Object? data) {
    if (data is! Map) return Selection();
    Map<String, Object?> map(Object? v) => v is Map ? {for (final e in v.entries) '${e.key}': e.value} : {};
    return Selection(
      groups: {for (final e in map(data['groups']).entries) e.key: e.value == true},
      channels: {
        for (final e in map(data['channels']).entries)
          if (e.value is Map)
            e.key: {
              for (final f in map(e.value).entries)
                if (f.value != null) f.key: f.value!,
            },
      },
      groupOrder: [for (final x in (data['group_order'] as List? ?? const [])) '$x'],
      channelOrder: [for (final x in (data['channel_order'] as List? ?? const [])) '$x'],
      groupNames: {
        for (final e in map(data['group_names']).entries)
          if ('${e.value ?? ''}'.trim().isNotEmpty) e.key: '${e.value}',
      },
    );
  }

  Map<String, dynamic> toJson() => {
    'groups': groups,
    'channels': channels,
    'group_order': groupOrder,
    'channel_order': channelOrder,
    'group_names': groupNames,
  };

  Selection copy() => Selection.fromJson(toJson());
}

/// The group's name as renamed on this TV, else the provider's.
String groupName(Group group, Selection sel) {
  final name = (sel.groupNames[group.id] ?? '').trim();
  return name.isEmpty ? group.name : name;
}

bool isShown(Channel channel, Selection sel) {
  final own = sel.channels[channel.key];
  if (own != null && own.containsKey('on')) return own['on'] == true;
  return sel.groups[channel.group] ?? false;
}

String displayName(Channel channel, Selection sel) {
  final name = '${sel.channels[channel.key]?['name'] ?? ''}'.trim();
  return name.isEmpty ? channel.name : name;
}

/// Items in their explicit order first (as listed), then the rest in their own order.
List<T> _ordered<T>(List<T> items, String Function(T) key, int Function(T) order, List<String> explicit) {
  final pos = {for (var i = 0; i < explicit.length; i++) explicit[i]: i};
  final indexed = [for (var i = 0; i < items.length; i++) (i, items[i])];
  indexed.sort((a, b) {
    final pa = pos[key(a.$2)];
    final pb = pos[key(b.$2)];
    final ra = pa == null ? 1 : 0;
    final rb = pb == null ? 1 : 0;
    if (ra != rb) return ra - rb;
    final va = pa ?? order(a.$2);
    final vb = pb ?? order(b.$2);
    if (va != vb) return va.compareTo(vb);
    return a.$1 - b.$1;
  });
  return [for (final e in indexed) e.$2];
}

List<Group> orderedGroups(Catalog catalog, Selection sel) =>
    _ordered(catalog.groups, (g) => g.id, (g) => g.order, sel.groupOrder);

/// Every channel of one group, shown or not, in this TV's order (for Manage channels).
List<Channel> orderedChannels(Catalog catalog, Selection sel, String groupId) => _ordered(
  [
    for (final c in catalog.channels)
      if (c.group == groupId) c,
  ],
  (c) => c.key,
  (c) => c.order,
  sel.channelOrder,
);

/// The channels to show, group by group in this TV's order, each group's channels in its order.
List<Channel> shownChannels(Catalog catalog, Selection sel) {
  final byGroup = <String, List<Channel>>{};
  for (final c in catalog.channels) {
    if (isShown(c, sel)) byGroup.putIfAbsent(c.group, () => []).add(c);
  }
  return [
    for (final g in orderedGroups(catalog, sel))
      ..._ordered(byGroup[g.id] ?? const <Channel>[], (c) => c.key, (c) => c.order, sel.channelOrder),
  ];
}

/// A new selection with the Manage screens' changes:
///
///     {group: id, on: bool}                    tick or untick a group
///     {group: id, name: String?}               rename a group ("" or null: the provider's name)
///     {channel: key, on: bool?}                show, hide, or follow the group again (null)
///     {channel: key, name: String?}            rename ("" or null: the provider's name)
///     {channel: key, guide: String?}           the guide channel ("<source>|<id>"; "" or null: automatic)
///     {order: [key, ...]}                      one group's channels in this order
Selection applyChanges(
  Selection sel,
  List<Map<String, Object?>> changes, {
  List<String>? groupOrder,
  List<String>? channelOrder,
}) {
  final out = sel.copy();
  for (final ch in changes) {
    if (ch.containsKey('order')) {
      // one group's channels in a new order: they move to the end of the list in that order, which leaves every other
      // group's order as it was (order only counts between channels of the same group)
      final keys = [for (final k in (ch['order'] as List? ?? const [])) '$k'];
      final moved = keys.toSet();
      out.channelOrder
        ..removeWhere(moved.contains)
        ..addAll(keys);
      continue;
    }
    if (ch.containsKey('group')) {
      final gid = '${ch['group']}';
      if (ch.containsKey('on')) {
        if (ch['on'] == true) {
          out.groups[gid] = true;
        } else {
          out.groups.remove(gid);
        }
      }
      if (ch.containsKey('name')) {
        final name = '${ch['name'] ?? ''}'.trim();
        if (name.isNotEmpty) {
          out.groupNames[gid] = name;
        } else {
          out.groupNames.remove(gid);
        }
      }
      continue;
    }
    if (!ch.containsKey('channel')) continue;
    final key = '${ch['channel']}';
    final own = Map<String, Object>.of(out.channels[key] ?? const {});
    if (ch.containsKey('on')) {
      final on = ch['on'];
      if (on == null) {
        own.remove('on');
      } else {
        own['on'] = on == true;
      }
    }
    for (final field in const ['name', 'guide']) {
      if (!ch.containsKey(field)) continue;
      final value = '${ch[field] ?? ''}'.trim();
      if (value.isNotEmpty) {
        own[field] = value;
      } else {
        own.remove(field);
      }
    }
    if (own.isNotEmpty) {
      out.channels[key] = own;
    } else {
      out.channels.remove(key);
    }
  }
  if (groupOrder != null) {
    out.groupOrder
      ..clear()
      ..addAll(groupOrder);
  }
  if (channelOrder != null) {
    out.channelOrder
      ..clear()
      ..addAll(channelOrder);
  }
  return out;
}

// ---- names and guide matching -----------------------------------------------------------------------------------------

final _prefix = RegExp(r'^\s*(?:[a-z]{2,3}(?:[-/][a-z0-9]{1,4})?|[a-z]{2,4}\s?\+?)\s*[:|]\s*', caseSensitive: false);
final _noise = RegExp(r'\b(?:fhd|uhd|hd|sd|4k|hevc|h265|1080p?|720p?|backup|raw|vip|live)\b', caseSensitive: false);
final _marks = RegExp('[Ⓐ-ⓩ]');
const _numbers = {'one': '1', 'two': '2', 'three': '3', 'four': '4', 'five': '5'};

/// The name without Free-TV's marks (Ⓖ geo-blocked, Ⓢ not 24/7, Ⓨ YouTube, Ⓣ Twitch), for showing.
String withoutMarks(String name) => name.replaceAll(_marks, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();

/// The name without a provider prefix ("UK: BBC 2" -> "BBC 2") or Free-TV's marks.
String tidyName(String name) {
  final text = withoutMarks(name);
  final stripped = text.replaceFirst(_prefix, '').trim();
  return stripped.isEmpty ? text : stripped;
}

const _countryNames = {
  'uk': 'GB',
  'gb': 'GB',
  'united kingdom': 'GB',
  'great britain': 'GB',
  'england': 'GB',
  'scotland': 'GB',
  'wales': 'GB',
  'northern ireland': 'GB',
  'ireland': 'IE',
  'ie': 'IE',
  'norway': 'NO',
  'no': 'NO',
  'sweden': 'SE',
  'se': 'SE',
  'denmark': 'DK',
  'dk': 'DK',
  'finland': 'FI',
  'fi': 'FI',
  'iceland': 'IS',
  'is': 'IS',
  'germany': 'DE',
  'de': 'DE',
  'austria': 'AT',
  'at': 'AT',
  'switzerland': 'CH',
  'ch': 'CH',
  'netherlands': 'NL',
  'nl': 'NL',
  'belgium': 'BE',
  'be': 'BE',
  'france': 'FR',
  'fr': 'FR',
  'spain': 'ES',
  'es': 'ES',
  'italy': 'IT',
  'it': 'IT',
  'portugal': 'PT',
  'pt': 'PT',
  'poland': 'PL',
  'pl': 'PL',
  'usa': 'US',
  'us': 'US',
  'united states': 'US',
  'canada': 'CA',
  'ca': 'CA',
  'australia': 'AU',
  'au': 'AU',
  'new zealand': 'NZ',
  'nz': 'NZ',
};

/// The country a channel belongs to, as an ISO code: the playlist's tvg-country, a prefix on the name ("DK: TV3",
/// "US-S: NHL NETWORK", "CA | NBA TV"), else its group when that names a country ("Denmark"). Null when nothing says.
/// A name alone is not enough: TV3 is a different channel in Norway, Sweden and Denmark (review, 24 Oct 2026).
String? countryHint({required String name, String? tvgCountry, String? group}) {
  final given = (tvgCountry ?? '').trim().toLowerCase();
  if (given.isNotEmpty) return _countryNames[given] ?? (given.length == 2 ? given.toUpperCase() : null);
  final m = _prefix.firstMatch(withoutMarks(name));
  if (m != null) {
    final tag = m.group(0)!.replaceAll(RegExp(r'[:|\s+]'), '').split(RegExp(r'[-/]')).first.toLowerCase();
    final code = _countryNames[tag];
    if (code != null) return code;
  }
  return _countryNames[(group ?? '').trim().toLowerCase()];
}

/// The country of an epgshare01 guide file from its label ("epgshare01 UK1" -> GB); null for any other guide.
String? guideCountry(String label) {
  final m = RegExp(r'^epgshare01 ([A-Za-z]{2})\d').firstMatch(label);
  if (m == null) return null;
  final tag = m.group(1)!.toLowerCase();
  return _countryNames[tag] ?? tag.toUpperCase();
}

// epgshare01's own naming (checked 19 Oct 2026): the Norway file says "NRK1 Norway (NO,NO)", the Sweden file
// "[DR1DK] DR1"; the UK file uses plain names. A country is only taken off before such a "(XX,YY)" ending, and the UK's
// nations are not countries here, so "BBC One Scotland (GB,EN)" keeps its Scotland.
final _bracketCode = RegExp(r'^\s*\[[^\]]*\]\s*');
final _epgEnding = RegExp(r'\s*\(\s*[A-Z]{2}\s*(?:,\s*[A-Z]{2,3}\s*)*\)\s*$');
final _countryWord = RegExp(
  r'\s+(?:norway|sweden|denmark|finland|iceland|ireland|germany|austria|switzerland|netherlands|belgium|france|'
  r'spain|italy|poland|portugal|united kingdom|great britain|uk|usa|united states|canada|australia)\s*$',
  caseSensitive: false,
);

/// A matching key: no prefix, no quality words, numbers as digits, letters and digits only.
/// "UK: BBC TWO FHD", "BBC Two HD" and "BBC 2" all give "bbc2"; "NRK1 Norway (NO,NO)" and "[DR1DK] DR1" give "nrk1"
/// and "dr1".
String normName(String name) {
  var plain = name.replaceFirst(_bracketCode, '');
  if (_epgEnding.hasMatch(plain)) plain = plain.replaceFirst(_epgEnding, '').replaceFirst(_countryWord, '');
  var text = foldAscii(tidyName(plain));
  text = text.replaceAll('&', ' and ').replaceAll('+', ' plus ');
  text = text.replaceAll(_noise, ' ');
  return [
    for (final w in text.split(RegExp(r'[^a-z0-9]+')))
      if (w.isNotEmpty) _numbers[w] ?? w,
  ].join();
}

/// One XMLTV source's channels: id -> display names, in source priority order (the provider's guide first).
class GuideSource {
  GuideSource(this.label, this.names);

  final String label;
  final Map<String, List<String>> names;

  Set<String> ids() => names.keys.toSet();

  Map<String, String> byNorm() {
    final out = <String, String>{};
    names.forEach((gid, list) {
      for (final n in list.isEmpty ? [gid] : list) {
        out.putIfAbsent(normName(n), () => gid);
      }
    });
    return out;
  }
}

/// channel key -> (source index, guide channel id, how): how is "manual" (picked by hand), "id" (the playlist's guide
/// id is in a guide) or "name" (a guide channel has the same name). Manual and id matches are looked for in every source
/// before any name match, so a name in the provider's guide never beats an exact id in another.
Map<String, (int, String, String)> matchGuides(Iterable<Channel> channels, Selection sel, List<GuideSource> sources) {
  final idSets = [for (final s in sources) s.ids()];
  final norms = [for (final s in sources) s.byNorm()];
  final out = <String, (int, String, String)>{};
  for (final c in channels) {
    final manual = '${sel.channels[c.key]?['guide'] ?? ''}'.trim();
    (int, String, String)? found;
    if (manual.isNotEmpty) {
      final bar = manual.indexOf('|');
      final src = bar < 0 ? '' : manual.substring(0, bar);
      final gid = bar < 0 ? manual : manual.substring(bar + 1);
      for (var i = 0; i < idSets.length; i++) {
        if (idSets[i].contains(gid) && (src.isEmpty || sources[i].label == src)) {
          found = (i, gid, 'manual');
          break;
        }
      }
    }
    final own = c.guideId;
    if (found == null && own != null) {
      for (var i = 0; i < idSets.length; i++) {
        if (idSets[i].contains(own)) {
          found = (i, own, 'id');
          break;
        }
      }
    }
    if (found == null) {
      final keys = {normName(displayName(c, sel)), normName(c.name)}..remove('');
      // by name: the channel's own country's file first, then the guides that belong to no country (the provider's, a
      // playlist's), and another country's file only when the channel's country is unknown
      final hint = c.country;
      final order = [
        for (var i = 0; i < norms.length; i++)
          if (hint != null && guideCountry(sources[i].label) == hint) i,
        for (var i = 0; i < norms.length; i++)
          if (guideCountry(sources[i].label) == null) i,
        for (var i = 0; i < norms.length; i++)
          if (hint == null && guideCountry(sources[i].label) != null) i,
      ];
      for (final i in order) {
        if (found != null) break;
        for (final k in keys) {
          final gid = norms[i][k];
          if (gid != null) {
            found = (i, gid, 'name');
            break;
          }
        }
      }
    }
    if (found != null) out[c.key] = found;
  }
  return out;
}

/// Guide channels whose id or a display name contains every word of the query (for the Manage screens).
List<({String source, int sourceIndex, String id, String name})> searchGuideChannels(
  List<GuideSource> sources,
  String query, {
  int limit = 25,
}) {
  final words = [
    for (final w in query.toLowerCase().trim().split(RegExp(r'\s+')))
      if (w.isNotEmpty) w,
  ];
  final out = <({String source, int sourceIndex, String id, String name})>[];
  for (var i = 0; i < sources.length; i++) {
    for (final e in sources[i].names.entries) {
      final hay = [e.key, ...e.value].join(' ').toLowerCase();
      if (words.every(hay.contains)) {
        out.add((source: sources[i].label, sourceIndex: i, id: e.key, name: e.value.isEmpty ? e.key : e.value.first));
        if (out.length >= limit) return out;
      }
    }
  }
  return out;
}

// ---- the guide at a moment --------------------------------------------------------------------------------------------

class Programme {
  const Programme(this.start, this.stop, this.title, [this.sub = '', this.desc = '', this.category = '']);

  /// Epoch seconds.
  final int start;
  final int stop;
  final String title;
  final String sub;
  final String desc;
  final String category;
}

(Programme?, Programme?) nowNext(List<Programme>? programmes, int now) {
  if (programmes == null || programmes.isEmpty) return (null, null);
  Programme? current;
  Programme? next;
  for (final p in programmes) {
    if (p.start <= now && now < p.stop) {
      current = p;
    } else if (p.start >= now) {
      next = p;
      break;
    }
  }
  return (current, next);
}

List<Programme> window(List<Programme>? programmes, int start, int end) => [
  for (final p in programmes ?? const <Programme>[])
    if (p.stop > start && p.start < end) p,
];
