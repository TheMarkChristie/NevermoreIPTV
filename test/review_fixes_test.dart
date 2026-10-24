// The 24 October 2026 review's fixes, each held by a check. Run: flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/guide_grid.dart';
import 'package:nevermore_iptv/core/library.dart';
import 'package:nevermore_iptv/core/m3u.dart';
import 'package:nevermore_iptv/core/model.dart';
import 'package:nevermore_iptv/core/player_state.dart';
import 'package:nevermore_iptv/core/presets.dart';
import 'package:nevermore_iptv/core/reasons.dart';
import 'package:nevermore_iptv/core/show_search.dart';
import 'package:nevermore_iptv/core/vpn.dart';
import 'package:nevermore_iptv/core/vpn_upload.dart';
import 'package:nevermore_iptv/core/xtream.dart';
import 'package:nevermore_iptv/ui/settings_page.dart' show appVersion;

void main() {
  group('failure text', () {
    test('the patched plug-in\'s cause carries the HTTP status; the wrapper comes off the raw line', () {
      const text =
          'PlatformException(VideoError, Video player had error androidx.media3.exoplayer.ExoPlaybackException: '
          'Source error [ERROR_CODE_IO_BAD_HTTP_STATUS] / androidx.media3.datasource.HttpDataSource\$'
          'InvalidResponseCodeException: Response code: 403, null, null)';
      expect(friendlyReason(text), 'The stream answered HTTP 403.');
      expect(rawReason(text), startsWith('ExoPlaybackException: Source error [ERROR_CODE_IO_BAD_HTTP_STATUS]'));
      expect(rawReason(text), isNot(contains('PlatformException')));
      expect(friendlyReason('x [ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT]'), 'The stream did not answer.');
      expect(friendlyReason('the stream ended'), contains('ended'));
    });
  });

  group('secrets', () {
    test('a login is masked in every encoding it travels in', () {
      final client = XtreamClient('http://h', 'u1', 'p w!(x)');
      final out = client.scrub(
        'ClientException with SocketException, uri=http://h/player_api.php?username=u1&password=p+w%21%28x%29',
      );
      expect(out, isNot(contains('p+w')));
      expect(out, isNot(contains('%21%28')));
      expect(out, isNot(contains('u1')));
      expect(
        redactSecrets('http://h/get.php?username=aa&password=bb&type=m3u_plus'),
        'http://h/get.php?username=***&password=***&type=m3u_plus',
      );
      expect(redactSecrets('http://h/live/aa/bb/123.ts'), 'http://h/live/***/***/123.ts');
    });
  });

  group('countries', () {
    test('a channel\'s country comes from tvg-country, a prefix on the name, or its group', () {
      expect(countryHint(name: 'DK: TV3'), 'DK');
      expect(countryHint(name: 'US-S: NHL NETWORK'), 'US');
      expect(countryHint(name: 'CA | NBA TV'), 'CA');
      expect(countryHint(name: 'UK: BBC ONE'), 'GB');
      expect(countryHint(name: 'TV3', tvgCountry: 'SE'), 'SE');
      expect(countryHint(name: 'TV3', group: 'Denmark'), 'DK');
      expect(countryHint(name: 'PPV 1'), isNull);
      expect(guideCountry('epgshare01 UK1'), 'GB');
      expect(guideCountry('epgshare01 NO1'), 'NO');
      expect(guideCountry('My provider guide'), isNull);
    });

    test('a name match prefers the channel\'s own country\'s file and refuses another country\'s', () {
      final sources = [
        GuideSource('epgshare01 NO1', {
          'tv3.no': ['TV3 Norway (NO,NO)'],
        }),
        GuideSource('epgshare01 DK1', {
          'tv3.dk': ['TV3 Denmark (DK,DA)'],
        }),
      ];
      final danish = matchGuides([const Channel('x', 'DK: TV3', 'dk', 0, country: 'DK')], Selection(), sources);
      expect(danish['x'], (1, 'tv3.dk', 'name'));
      final swedish = matchGuides([const Channel('y', 'SE: TV3', 'se', 0, country: 'SE')], Selection(), sources);
      expect(swedish.containsKey('y'), isFalse);
      final unknown = matchGuides([const Channel('z', 'TV3', 'g', 0)], Selection(), sources);
      expect(unknown['z'], (0, 'tv3.no', 'name'));
    });
  });

  group('player state', () {
    test('a completed flag while still playing is a live stream with a fake duration, not the end', () {
      // 24 Oct 2026, the radio stream: duration 1 ms, position 1 ms, playing, completed - twice a second
      expect(streamEnded(hasError: false, completed: true, playing: true, buffering: false), isFalse);
      expect(streamEnded(hasError: false, completed: true, playing: false, buffering: true), isFalse);
      expect(streamEnded(hasError: false, completed: true, playing: false, buffering: false), isTrue);
      expect(streamEnded(hasError: true, completed: false, playing: true, buffering: false), isTrue);
      expect(streamEnded(hasError: false, completed: false, playing: false, buffering: false), isFalse);
    });
  });

  group('playlist keys', () {
    test('keys stay with their channel when the playlist is reordered', () {
      M3uEntry e(String name, String url) => M3uEntry(name: name, url: url, group: 'G');
      final a = catalogFromM3u([
        e('One', 'http://s/1'),
        e('Twin', 'http://s/2'),
        e('Twin', 'http://s/3'),
        e('Кино', 'http://s/4'),
      ]);
      final b = catalogFromM3u([
        e('Кино', 'http://s/4'),
        e('Twin', 'http://s/3'),
        e('Twin', 'http://s/2'),
        e('One', 'http://s/1'),
      ]);
      String keyOf(Catalog c, String url) => c.channels.firstWhere((ch) => ch.url == url).key;
      expect(keyOf(a, 'http://s/1'), 'g/one');
      for (final url in ['http://s/1', 'http://s/2', 'http://s/3', 'http://s/4']) {
        expect(keyOf(a, url), keyOf(b, url), reason: url);
      }
      expect({for (final c in a.channels) c.key}.length, 4);
      expect(stableHash('http://s/3'), stableHash('http://s/3'));
      expect(stableHash('a'), isNot(stableHash('b')));
    });
  });

  group('guide grid', () {
    test('a show found for tomorrow evening has a cell to land on', () {
      const now = 1000000000;
      final rows = [
        [Programme(now + 20 * 3600, now + 21 * 3600, 'Late film', '', '', '')],
      ];
      final g = GuideGrid(rows: rows, now: now);
      g.focusTime(now + 20 * 3600 + 60);
      expect(g.cell?.programme?.title, 'Late film');
      expect(g.time >= g.windowStart && g.time < g.windowEnd, isTrue);
    });
  });

  group('presets', () {
    test('a preset keeps the viewer\'s renames and guide picks, and an empty match says so', () {
      final catalog = Catalog(
        groups: const [Group('7', 'NHL', 0)],
        channels: const [Channel('2', 'NHL: SEATTLE KRAKEN', '7', 0)],
      );
      final preset = presetsFromJson({
        'presets': [
          {
            'code': '1',
            'name': 'P',
            'groups': [
              {
                'group': 'NHL',
                'channels': ['kraken'],
              },
            ],
          },
        ],
      }).single;
      final previous = Selection(
        channels: {
          '2': {'name': 'Kraken', 'guide': 'g|x', 'on': false},
        },
      );
      final r = applyPreset(catalog, preset, previous: previous);
      expect(r.selection.channels['2'], {'name': 'Kraken', 'guide': 'g|x', 'on': true});
      expect(r.shown, 1);
      final none = applyPreset(
        catalog,
        presetsFromJson({
          'presets': [
            {
              'code': '2',
              'name': 'Q',
              'groups': [
                {'group': 'NFL', 'all': true},
              ],
            },
          ],
        }).single,
      );
      expect(none.shown, 0);
      expect(none.missing, ['NFL']);
    });
  });

  group('vpn', () {
    test('the plug-in\'s codes and the second country oracle are read', () {
      expect(vpnStartFailure(PlatformException(code: 'DNS_RESOLUTION_FAILURE')), contains('could not be found'));
      expect(vpnStartFailure(PlatformException(code: 'PERMISSION_DENIED')), contains('not allowed'));
      expect(vpnStartFailure(PlatformException(code: 'ODD')), contains('ODD'));
      expect(countryFromJson('{"ip":"1.2.3.4","country":"NL"}'), 'NL');
      expect(countryFromJson('not json'), isNull);
      expect(countryFromJson('{"country":"Netherlands"}'), isNull);
    });
  });

  group('search days', () {
    test('tomorrow is tomorrow on the day the clocks go forward', () {
      final now = DateTime(2026, 3, 29, 12).millisecondsSinceEpoch ~/ 1000;
      final show = DateTime(2026, 3, 30, 20).millisecondsSinceEpoch ~/ 1000;
      expect(dayAndTime(show, now), 'Tomorrow 20:00');
    });
  });

  group('library files', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nevermore_lib'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('two writes of one file in flight leave valid JSON with the later state', () async {
      final lib = Library(folder: tmp);
      final first = lib.change('s', [
        {'channel': 'a', 'on': true},
      ]);
      final second = lib.change('s', [
        {'channel': 'a', 'on': null},
      ]);
      await Future.wait([first, second]);
      final text = File('${tmp.path}${Platform.pathSeparator}selection-s.json').readAsStringSync();
      final data = jsonDecode(text) as Map;
      final own = (data['channels'] as Map)['a'];
      expect(own == null || !(own as Map).containsKey('on'), isTrue, reason: 'the later change wins');
      expect(tmp.listSync().where((f) => f.path.endsWith('.part')), isEmpty);
      lib.dispose();
    });
  });

  group('upload page', () {
    test('a browser\'s icon request is not a wrong code; five wrong codes from one caller close it', () async {
      final server = VpnUploadServer(accept: (_) async => null);
      final port = await server.start();
      final client = HttpClient();
      Future<int> get(String path) async {
        final req = await client.get('127.0.0.1', port, path);
        final res = await req.close();
        await res.drain<void>();
        return res.statusCode;
      }

      for (var i = 0; i < 6; i++) {
        expect(await get('/favicon.ico'), 204);
      }
      expect(await get('/${server.code}'), 200);
      for (var i = 0; i < 5; i++) {
        expect(await get('/wrong$i'), 404);
      }
      await server.closed.timeout(const Duration(seconds: 5));
      client.close(force: true);
    });
  });

  test('the version shown in Settings is the one in pubspec.yaml', () {
    final line = File('pubspec.yaml').readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
    expect(line.split(':')[1].trim(), startsWith('$appVersion+'));
  });
}
