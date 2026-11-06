/// A picks file: everything a TV was set up with, written by one TV and read by another (Mark, 6 Nov 2026: "export and
/// restore the picks", with the logins in it - his choice). The library writes and reads it (`exportPicks`,
/// `restorePicks`); this is the file's shape and its check.
///
///     {"nevermore_picks": 1, "exported": "2026-11-06T22:10:00Z", "app": "0.7.12",
///      "sources": [...], "selections": {"<source id>": {...}}, "group_order": [...], "epg": ["UK"],
///      "fill": false, "pages": {"<site>": "<page>"}, "radio": ["<uid>"]}
library;

const picksFormat = 1;
const picksFileName = 'nevermore-picks.json';

/// Why [data] is not a picks file this version can read; null when it is one.
String? picksProblem(Object? data) {
  if (data is! Map) return 'Not a picks file.';
  final format = data['nevermore_picks'];
  if (format is! int) return 'Not a Nevermore IPTV picks file.';
  if (format > picksFormat) return 'A picks file from a newer version: update this TV first.';
  if (data['sources'] is! List) return 'The file has no sources.';
  for (final s in data['sources'] as List) {
    if (s is! Map || s['id'] is! String || s['kind'] is! String || s['url'] is! String) {
      return 'A source in the file is not readable.';
    }
  }
  return null;
}
