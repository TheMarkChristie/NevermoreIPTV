/// My Teams, built in: the My Teams TV page (Mark's teams' highlights, results, fixtures, tables and news ticker, the
/// MyTeamsTV project) served from inside the app and listed first in the guide's Web category. Mark, 15 Nov 2026: "add
/// to my Nevermore IPTV as a channel that is built in".
///
/// The page is the same file MyTeamsTV's serve.py serves (assets/myteams/index.html, copied there by its
/// `build.py --nevermore`), and this answers the same calls, so the page cannot tell the two apart:
///
///     GET /                        the page          GET /icon.png    the channel's logo
///     GET /api/config              {"server": "nevermore", "key": true, "config": {teams, feeds, options}}
///     GET /api/tsdb/v2/<path>      TheSportsDB v2 (schedule/, lookup/, livescore/ only), the key as X-API-KEY
///     GET /api/tsdb/v1/<call>      TheSportsDB v1 (lookuptable, lookupevent, eventsday only)
///     GET /api/rss?u=<address>     a feed the config names, and no other address
///
/// The page plays highlights only from a house's library of downloaded videos (its api/media), never from YouTube
/// (Mark, 21 Nov 2026: "there should be no YouTube mode so remove that"). This built-in copy has no library, so it
/// shows results, fixtures, tables and news; the highlights are on the copy a house hosts.
///
/// Why a server and not a file: the news feeds send no CORS header, so a page cannot read them itself. The server listens on 127.0.0.1 only, on one
/// fixed port so the Web category's address (and the icon kept for it) stays the same from start to start.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'presets.dart';

const myTeamsPort = 47390;
const myTeamsName = 'CMHjem TV';
const myTeamsUrl = 'http://127.0.0.1:$myTeamsPort/';
const _tsdb = 'https://www.thesportsdb.com/api';

final _v2Allowed = RegExp(
  r'^(schedule/(next|previous)/(team|league)/\d+|lookup/(team|league|event)/\d+|livescore/[a-z_]+|livescore/\d+)$',
);
final _v1Allowed = RegExp(r'^(lookuptable|lookupevent|lookuptv|eventsday)\.php$');

/// Where the My Teams channel opens: the house's hosted copy when the house file names one and it answers (Mark, 15
/// Nov 2026: hosted on the Scotland Home Assistant, which also hands the page HA Team Scores' UK and Norwegian
/// channels), else this app's own server. Null when this copy has no My Teams at all.
Future<String?> myTeamsAddress() async {
  final setup = await loadMyTeams();
  if (setup == null) return null;
  final hosted = setup.url;
  if (hosted != null) {
    try {
      final r = await http.get(Uri.parse(hosted).resolve('api/config')).timeout(const Duration(seconds: 6));
      final body = r.statusCode == 200 ? jsonDecode(r.body) : null;
      if (body is Map && body['server'] != null) return hosted;
      debugPrint('my teams: $hosted answered ${r.statusCode}; the built-in copy instead');
    } catch (e) {
      debugPrint('my teams: $hosted did not answer ($e); the built-in copy instead');
    }
  }
  return (await MyTeamsServer.ensure()) != null ? myTeamsUrl : null;
}

/// What a request asks for.
sealed class MyTeamsRoute {
  const MyTeamsRoute();
}

class PageRoute extends MyTeamsRoute {
  const PageRoute(this.asset, this.contentType);

  final String asset;
  final String contentType;
}

class ConfigRoute extends MyTeamsRoute {
  const ConfigRoute();
}

class TsdbRoute extends MyTeamsRoute {
  const TsdbRoute(this.version, this.path, this.query);

  final String version; // v1 or v2
  final String path;
  final String query;
}

class RssRoute extends MyTeamsRoute {
  const RssRoute(this.url);

  final String url;
}

class RefusedRoute extends MyTeamsRoute {
  const RefusedRoute(this.status, this.reason);

  final int status;
  final String reason;
}

/// The route for [uri], given the feeds the config allows.
MyTeamsRoute myTeamsRoute(Uri uri, Map<String, dynamic> config) {
  final path = uri.path;
  if (path == '/' || path == '/index.html') return const PageRoute('assets/myteams/index.html', 'text/html; charset=utf-8');
  if (path == '/icon.png') return const PageRoute('assets/myteams/icon.png', 'image/png');
  if (path == '/api/config') return const ConfigRoute();
  final m = RegExp(r'^/api/tsdb/(v1|v2)/(.+)$').firstMatch(path);
  if (m != null) {
    final version = m.group(1)!;
    final sub = Uri.decodeComponent(m.group(2)!);
    final allowed = version == 'v2' ? _v2Allowed : _v1Allowed;
    if (!allowed.hasMatch(sub)) return const RefusedRoute(403, 'not an allowed TheSportsDB call');
    return TsdbRoute(version, sub, uri.query);
  }
  if (path == '/api/rss') {
    final url = (uri.queryParameters['u'] ?? '').trim();
    final feeds = config['feeds'];
    // a news feed of the config and no other address (a YouTube channel's feed neither: the page asks nothing of
    // YouTube since 0.99.10000)
    final known = feeds is List && feeds.any((f) => f is Map && '${f['url'] ?? ''}'.trim() == url);
    if (url.isEmpty || !known) return const RefusedRoute(403, 'not a feed in the config');
    return RssRoute(url);
  }
  return const RefusedRoute(404, 'not found');
}

/// How long an answer is kept: live scores briefly, schedules for minutes, tables longer, lookups for hours.
Duration myTeamsTtl(MyTeamsRoute r) {
  if (r is RssRoute) return const Duration(minutes: 8);
  if (r is! TsdbRoute) return Duration.zero;
  if (r.version == 'v2') {
    if (r.path.startsWith('livescore/')) return const Duration(seconds: 25);
    if (r.path.startsWith('schedule/')) return const Duration(minutes: 4);
    return const Duration(hours: 6);
  }
  if (r.path.startsWith('lookuptable')) return const Duration(minutes: 20);
  if (r.path.startsWith('lookupevent')) return const Duration(minutes: 1);
  if (r.path.startsWith('lookuptv')) return const Duration(hours: 3);
  return const Duration(minutes: 2);
}

class _Answer {
  _Answer(this.status, this.body, this.contentType, this.until);

  final int status;
  final Uint8List body;
  final String contentType;
  final DateTime until;
}

class MyTeamsServer {
  MyTeamsServer._(this.setup, this._server);

  final MyTeamsSetup setup;
  final HttpServer _server;
  // its own client with a connect limit: a TV's first address for a host can hang until the system gives up (minutes)
  final http.Client _client = IOClient(
    HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 20),
  );
  final _cache = <String, _Answer>{};
  final _inflight = <String, Future<_Answer>>{};
  final _assets = <String, Uint8List>{};
  Future<void> _pace = Future.value();

  static Future<MyTeamsServer?>? _running;

  /// Stops listening (the app's process ending does the same).
  Future<void> close() async {
    _client.close();
    await _server.close(force: true);
  }

  /// The server, started on first use; null when this copy has no My Teams setup or the port is taken.
  static Future<MyTeamsServer?> ensure() => _running ??= _start();

  static Future<MyTeamsServer?> _start() async {
    final setup = await loadMyTeams();
    if (setup == null || setup.key.isEmpty) return null;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, myTeamsPort);
      final s = MyTeamsServer._(setup, server);
      server.listen((req) => unawaited(s._handle(req)), onError: (Object e) => debugPrint('my teams: $e'));
      return s;
    } catch (e) {
      debugPrint('my teams: no server on port $myTeamsPort: $e');
      return null;
    }
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final route = myTeamsRoute(req.uri, setup.config);
      switch (route) {
        case PageRoute(:final asset, :final contentType):
          final bytes = _assets[asset] ??= (await rootBundle.load(asset)).buffer.asUint8List();
          await _send(res, 200, bytes, contentType, cache: 'no-cache');
        case ConfigRoute():
          final body = jsonEncode({'server': 'nevermore', 'key': true, 'config': setup.config});
          await _send(res, 200, utf8.encode(body), 'application/json');
        case TsdbRoute() || RssRoute():
          final a = await _upstream(route);
          await _send(res, a.status, a.body, a.status == 200 ? a.contentType : 'text/plain');
        case RefusedRoute(:final status, :final reason):
          await _send(res, status, utf8.encode(reason), 'text/plain');
      }
    } catch (e) {
      try {
        await _send(res, 500, utf8.encode('$e'), 'text/plain');
      } catch (_) {
        // the page went away
      }
    }
  }

  Future<void> _send(HttpResponse res, int status, List<int> body, String type, {String cache = 'no-store'}) async {
    res.statusCode = status;
    res.headers
      ..set(HttpHeaders.contentTypeHeader, type)
      ..set(HttpHeaders.cacheControlHeader, cache);
    res.contentLength = body.length;
    res.add(body);
    await res.close();
  }

  /// A cached answer while it is fresh; one call for many asks; TheSportsDB asked no faster than one call in 0.35 s;
  /// an old good answer kept over a fresh failure.
  Future<_Answer> _upstream(MyTeamsRoute route) {
    final key = route is TsdbRoute ? '${route.version}|${route.path}?${route.query}' : 'rss|${(route as RssRoute).url}';
    final hit = _cache[key];
    if (hit != null && hit.until.isAfter(DateTime.now())) return Future.value(hit);
    // the block body matters: `() => _inflight.remove(key)` hands whenComplete the very future it is completing, and
    // whenComplete waits for a future its callback returns - the answer never came (seen on the emulator, 15 Nov 2026)
    return _inflight[key] ??= _fetch(route, key).whenComplete(() {
      _inflight.remove(key);
    });
  }

  Future<_Answer> _fetch(MyTeamsRoute route, String key) async {
    final ttl = myTeamsTtl(route);
    late Uri uri;
    final headers = <String, String>{'User-Agent': 'NevermoreIPTV MyTeams'};
    if (route is TsdbRoute) {
      final q = route.query.isEmpty ? '' : '?${route.query}';
      if (route.version == 'v2') {
        uri = Uri.parse('$_tsdb/v2/json/${route.path}$q');
        headers['X-API-KEY'] = setup.key;
      } else {
        uri = Uri.parse('$_tsdb/v1/json/${Uri.encodeComponent(setup.key)}/${route.path}$q');
      }
      final turn = _pace.then((_) => Future<void>.delayed(const Duration(milliseconds: 350)));
      _pace = turn;
      await _pace;
    } else {
      uri = Uri.parse((route as RssRoute).url);
      headers['Accept'] = 'application/rss+xml, application/atom+xml, text/xml, */*';
    }
    _Answer a;
    final clock = Stopwatch()..start();
    final what = route is TsdbRoute ? route.path : uri.host;
    try {
      final r = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 20));
      a = _Answer(r.statusCode, r.bodyBytes, r.headers['content-type'] ?? 'application/octet-stream',
          DateTime.now().add(r.statusCode == 200 ? ttl : (ttl < const Duration(seconds: 30) ? ttl : const Duration(seconds: 30))));
      debugPrint('my teams: $what ${r.statusCode} in ${clock.elapsedMilliseconds} ms');
    } catch (e) {
      debugPrint('my teams: $what failed in ${clock.elapsedMilliseconds} ms: $e');
      a = _Answer(502, utf8.encode('upstream unreachable'), 'text/plain', DateTime.now().add(const Duration(seconds: 30)));
    }
    final old = _cache[key];
    if (a.status != 200 && old != null && old.status == 200) {
      a = _Answer(old.status, old.body, old.contentType, a.until);
    }
    _cache[key] = a;
    if (_cache.length > 1500) {
      final now = DateTime.now();
      _cache.removeWhere((_, v) => v.until.isBefore(now));
    }
    return a;
  }
}
