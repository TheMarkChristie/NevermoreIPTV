/// The guide's Web category: the house file's sites listed like channels, each with its own favicon as the logo; OK
/// opens one in the browser (web_page.dart). Mark, 24 Oct 2026: "they should appear in the EPG list under Web and then
/// when i select on web the 3 channels are listed and open the breowser in that url".
library;

import 'package:http/http.dart' as http;

import 'library.dart';
import 'model.dart';
import 'presets.dart';
import 'sources.dart';

const webSourceId = 'web';
const webCategoryName = 'Web';

/// Desktop Chrome: the sites lay out for a big screen and a pointer, and some refuse a WebView's own agent.
const browserUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

bool isWeb(PlayableChannel ch) => ch.source.id == webSourceId;

final _link = RegExp(r'<link\b[^>]*>', caseSensitive: false);
final _attr = RegExp(r'''([a-zA-Z-]+)\s*=\s*["']([^"']*)["']''');
final _size = RegExp(r'(\d+)x\d+');

/// The best icon a page names: the largest "icon" (an apple-touch-icon counts as 180); null when it names none.
Uri? namedIconUrl(String html, Uri page) {
  Uri? best;
  var bestSize = -1;
  for (final m in _link.allMatches(html)) {
    final a = {for (final x in _attr.allMatches(m.group(0)!)) x.group(1)!.toLowerCase(): x.group(2)!};
    final rel = (a['rel'] ?? '').toLowerCase();
    final href = (a['href'] ?? '').trim();
    if (href.isEmpty || !rel.contains('icon') || rel.contains('mask')) continue;
    final size = int.tryParse(_size.firstMatch(a['sizes'] ?? '')?.group(1) ?? '') ?? (rel.contains('apple') ? 180 : 16);
    if (size > bestSize) {
      bestSize = size;
      best = page.resolve(href);
    }
  }
  return best;
}

/// The site's icon address: the one its page names, else the first of the usual places that is a picture (a page
/// built by script names none, and its /favicon.ico can be the page itself, as one of Mark's sites did on 24 Oct 2026).
Future<String> faviconFor(String url) async {
  final page = Uri.parse(url);
  const headers = {'User-Agent': browserUserAgent};
  const wait = Duration(seconds: 10);
  try {
    final named = namedIconUrl((await http.get(page, headers: headers).timeout(wait)).body, page);
    if (named != null) return named.toString();
  } catch (_) {
    // unreadable: try the usual places
  }
  for (final path in const ['/favicon.ico', '/favicon.png', '/apple-touch-icon.png']) {
    final icon = page.resolve(path);
    try {
      final resp = await http.get(icon, headers: headers).timeout(wait);
      if (resp.statusCode == 200 && (resp.headers['content-type'] ?? '').startsWith('image/')) return icon.toString();
    } catch (_) {
      // not there
    }
  }
  return page.resolve('/favicon.ico').toString();
}

/// The Web category, or null when this copy has no sites.
Future<Category?> webCategory() async {
  final sites = await loadSites();
  if (sites.isEmpty) return null;
  final source = Source(id: webSourceId, kind: SourceKind.m3u, name: webCategoryName, url: '');
  final icons = await Future.wait([for (final s in sites) faviconFor(s.url)]);
  return Category(webCategoryName, [
    for (final (i, s) in sites.indexed)
      PlayableChannel(
        source,
        Channel(s.url, s.name, webSourceId, i, logo: icons[i], url: s.url),
        s.name,
        webCategoryName,
      ),
  ], []);
}
