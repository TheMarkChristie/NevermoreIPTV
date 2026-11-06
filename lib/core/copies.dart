/// The provider's other copies of a channel, for the quality fallback (Mark, 6 Nov 2026, picked "quality fallback":
/// the house list keeps one copy of each Sky Sports channel, and when that copy fails the app should move to another
/// by itself). The provider carries the same channel several times, the name differing only by a quality word: "SKY
/// SPORTS MAIN EVENT 4K", "... HD", "... HEVC". Copies are the channels of the same source whose matching key
/// (`normName`, which already drops those words) is equal, ticked or not, ordered by their quality word: 4K / UHD,
/// then HEVC / H265, then FHD / 1080, then HD / 720, then SD, then none.
library;

import 'model.dart';

final _words = [
  (RegExp(r'\b(?:4k|uhd|2160p?)\b', caseSensitive: false), 0),
  (RegExp(r'\b(?:hevc|h265)\b', caseSensitive: false), 1),
  (RegExp(r'\b(?:fhd|1080p?)\b', caseSensitive: false), 2),
  (RegExp(r'\b(?:hd|720p?)\b', caseSensitive: false), 3),
  (RegExp(r'\bsd\b', caseSensitive: false), 4),
];

/// 0 for the best quality word in [name] (4K), 4 for SD, 5 for none.
int qualityRank(String name) {
  for (final (re, rank) in _words) {
    if (re.hasMatch(name)) return rank;
  }
  return 5;
}

/// The quality word that tells a copy apart, as the name has it ("4K", "HEVC", "HD"); '' when it has none.
String qualityWord(String name) {
  for (final (re, _) in _words) {
    final m = re.firstMatch(name);
    if (m != null) return m.group(0)!.toUpperCase();
  }
  return '';
}

/// The other copies of [ch] in [catalog], best first; the channel itself is not among them.
List<Channel> copiesOf(Catalog catalog, Channel ch) {
  final key = normName(ch.name);
  if (key.isEmpty) return const [];
  final out = [
    for (final c in catalog.channels)
      if (c.key != ch.key && normName(c.name) == key) c,
  ];
  out.sort((a, b) => qualityRank(a.name).compareTo(qualityRank(b.name)));
  return out;
}

/// What to try after [failed] (the channel [ch] itself or one of its copies): the ring of the channel and its copies
/// in quality order, from the one after [failed] round to the one before it. Empty without copies.
List<Channel> copiesAfter(Catalog catalog, Channel ch, Channel failed) {
  final ring = [ch, ...copiesOf(catalog, ch)];
  if (ring.length < 2) return const [];
  // a stable sort: the channel itself stays ahead of a copy with the same word
  final indexed = [for (var i = 0; i < ring.length; i++) (i, ring[i])];
  indexed.sort((a, b) {
    final byRank = qualityRank(a.$2.name).compareTo(qualityRank(b.$2.name));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  final sorted = [for (final (_, c) in indexed) c];
  var at = sorted.indexWhere((c) => c.key == failed.key);
  if (at < 0) at = 0;
  return [for (var i = 1; i < sorted.length; i++) sorted[(at + i) % sorted.length]];
}
