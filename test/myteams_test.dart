// The built-in My Teams channel: the house file's setup, and what its server answers. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/myteams_server.dart';
import 'package:nevermore_iptv/core/presets.dart';

void main() {
  const config = {
    'teams': [
      {'id': '133602', 'name': 'Liverpool'},
    ],
    'feeds': [
      {'name': 'Liverpool', 'url': 'https://feeds.example/liverpool.xml'},
    ],
  };

  test('the setup needs a key and at least one team', () {
    final s = myTeamsFromJson({'myteams': {'key': ' abc ', 'config': config}});
    expect(s, isNotNull);
    expect(s!.key, 'abc');
    expect(s.config['teams'], hasLength(1));
    expect(myTeamsFromJson({'myteams': {'key': '', 'config': config}}), isNull);
    expect(myTeamsFromJson({'myteams': {'key': 'abc', 'config': {'teams': []}}}), isNull);
    expect(myTeamsFromJson({'sites': []}), isNull);
    expect(myTeamsFromJson(null), isNull);
  });

  test('a hosted address is opened first; with it no key is needed', () {
    final s = myTeamsFromJson({'myteams': {'key': 'abc', 'config': config, 'url': 'https://sco.example.com/myteams'}});
    expect(s!.url, 'https://sco.example.com/myteams/');
    final hostedOnly = myTeamsFromJson({'myteams': {'url': 'https://sco.example.com/myteams/'}});
    expect(hostedOnly, isNotNull);
    expect(hostedOnly!.key, isEmpty);
    expect(myTeamsFromJson({'myteams': {'url': 'ftp://x'}}), isNull);
    expect(myTeamsFromJson({'myteams': {'key': 'abc', 'config': config, 'url': 'not an address'}})!.url, isNull);
  });

  MyTeamsRoute route(String path) => myTeamsRoute(Uri.parse('http://127.0.0.1:$myTeamsPort$path'), config);

  test('the page, its logo and the config', () {
    expect((route('/') as PageRoute).asset, 'assets/myteams/index.html');
    expect((route('/index.html') as PageRoute).asset, 'assets/myteams/index.html');
    expect((route('/icon.png') as PageRoute).contentType, 'image/png');
    expect(route('/api/config'), isA<ConfigRoute>());
    expect((route('/nothing') as RefusedRoute).status, 404);
  });

  test('only the TheSportsDB calls the page makes are passed on', () {
    final next = route('/api/tsdb/v2/schedule/next/team/133602') as TsdbRoute;
    expect(next.version, 'v2');
    expect(next.path, 'schedule/next/team/133602');
    expect(route('/api/tsdb/v2/livescore/ice_hockey'), isA<TsdbRoute>());
    expect(route('/api/tsdb/v2/lookup/league/4328'), isA<TsdbRoute>());
    final table = route('/api/tsdb/v1/lookuptable.php?l=4328&s=2026-2027') as TsdbRoute;
    expect(table.query, 'l=4328&s=2026-2027');
    for (final p in [
      '/api/tsdb/v2/search/team/x',
      '/api/tsdb/v1/searchteams.php?t=x',
      '/api/tsdb/v2/schedule/next/team/1/../../x',
      '/api/tsdb/v3/anything',
    ]) {
      final r = route(p);
      expect(r is RefusedRoute ? r.status : 0, p.contains('v3') ? 404 : 403, reason: p);
    }
  });

  test('only the feeds the config names are read', () {
    final ok = route('/api/rss?u=${Uri.encodeComponent('https://feeds.example/liverpool.xml')}') as RssRoute;
    expect(ok.url, 'https://feeds.example/liverpool.xml');
    expect((route('/api/rss?u=${Uri.encodeComponent('http://192.168.1.1/')}') as RefusedRoute).status, 403);
    expect((route('/api/rss') as RefusedRoute).status, 403);
  });

  test('answers are kept: live scores briefly, schedules minutes, lookups hours', () {
    expect(myTeamsTtl(const TsdbRoute('v2', 'livescore/soccer', '')), const Duration(seconds: 25));
    expect(myTeamsTtl(const TsdbRoute('v2', 'schedule/next/team/1', '')), const Duration(minutes: 4));
    expect(myTeamsTtl(const TsdbRoute('v2', 'lookup/team/1', '')), const Duration(hours: 6));
    expect(myTeamsTtl(const TsdbRoute('v1', 'lookuptable.php', 'l=1')), const Duration(minutes: 20));
    expect(myTeamsTtl(const RssRoute('https://x')), const Duration(minutes: 8));
  });
}
