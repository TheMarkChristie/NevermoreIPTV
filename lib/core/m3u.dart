/// M3U / M3U8 playlist reading (extended M3U as IPTV providers and Free-TV write it). Port of the IPTV Player's
/// m3u.py.
///
///     #EXTM3U x-tvg-url="https://a.xml.gz, https://b.xml.gz"
///     #EXTINF:-1 tvg-id="BBCOne.uk" tvg-name="BBC One" tvg-logo="https://..." group-title="UK",BBC One Ⓖ
///     #EXTVLCOPT:http-user-agent=...
///     https://example/bbc_one.m3u8
library;

final _attr = RegExp(r'([A-Za-z0-9_-]+)="([^"]*)"');

class M3uEntry {
  const M3uEntry({
    required this.name,
    required this.url,
    this.group,
    this.tvgId,
    this.logo,
    this.chno,
    this.country,
    this.userAgent,
    this.referrer,
  });

  final String name;
  final String url;
  final String? group;
  final String? tvgId;
  final String? logo;
  final String? chno;
  final String? country;
  final String? userAgent;
  final String? referrer;
}

Map<String, String> _attrs(String text) => {for (final m in _attr.allMatches(text)) m.group(1)!: m.group(2)!};

String? _blank(String? text) {
  final t = (text ?? '').trim();
  return t.isEmpty ? null : t;
}

/// '#EXTINF:-1 a="x, y" b="z",Name, with comma' -> ({a: 'x, y', b: 'z'}, 'Name, with comma'). The title starts at the
/// first comma outside quotes.
(Map<String, String>, String) _splitExtinf(String line) {
  final body = line.substring('#EXTINF:'.length);
  var quoted = false;
  for (var i = 0; i < body.length; i++) {
    final ch = body[i];
    if (ch == '"') {
      quoted = !quoted;
    } else if (ch == ',' && !quoted) {
      return (_attrs(body.substring(0, i)), body.substring(i + 1).trim());
    }
  }
  return (_attrs(body), '');
}

/// The guide addresses an #EXTM3U header names (x-tvg-url / url-tvg, comma separated).
List<String> headerGuides(String text) {
  for (final raw in text.split(RegExp(r'\r?\n')).take(5)) {
    final line = raw.replaceFirst('﻿', '');
    if (!line.startsWith('#EXTM3U')) continue;
    final attrs = _attrs(line);
    final value = attrs['x-tvg-url'] ?? attrs['url-tvg'] ?? '';
    return [
      for (final u in value.split(','))
        if (u.trim().startsWith('http://') || u.trim().startsWith('https://')) u.trim(),
    ];
  }
  return const [];
}

List<M3uEntry> parseM3u(String text) {
  final entries = <M3uEntry>[];
  Map<String, String>? attrs;
  var title = '';
  String? groupLine;
  var opts = <String, String>{};
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim().replaceFirst('﻿', '');
    if (line.isEmpty) continue;
    if (line.startsWith('#EXTINF:')) {
      (attrs, title) = _splitExtinf(line);
      groupLine = null;
      opts = {};
    } else if (line.startsWith('#EXTGRP:')) {
      groupLine = _blank(line.substring('#EXTGRP:'.length));
    } else if (line.startsWith('#EXTVLCOPT:')) {
      final option = line.substring('#EXTVLCOPT:'.length);
      final eq = option.indexOf('=');
      final key = (eq < 0 ? option : option.substring(0, eq)).trim().toLowerCase();
      opts[key] = eq < 0 ? '' : option.substring(eq + 1).trim();
    } else if (line.startsWith('#')) {
      continue;
    } else if (attrs != null) {
      final a = attrs;
      final name = title.isNotEmpty ? title : (_blank(a['tvg-name']) ?? line);
      entries.add(
        M3uEntry(
          name: name.trim(),
          url: line,
          group: _blank(a['group-title']) ?? groupLine,
          tvgId: _blank(a['tvg-id']),
          logo: _blank(a['tvg-logo']),
          chno: _blank(a['tvg-chno']),
          country: _blank(a['tvg-country']),
          userAgent: _blank(opts['http-user-agent']),
          referrer: _blank(opts['http-referrer']) ?? _blank(opts['http-referer']),
        ),
      );
      attrs = null;
      title = '';
      groupLine = null;
      opts = {};
    }
  }
  return entries;
}
