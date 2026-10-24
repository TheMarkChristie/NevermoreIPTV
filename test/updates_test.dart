// The update check against GitHub releases (0.7.4). Run: flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nevermore_iptv/core/updates.dart';

Map<String, Object?> _release(String tag, {List<Map<String, Object?>>? assets, bool draft = false}) => {
  'tag_name': tag,
  'draft': draft,
  'html_url': 'https://github.com/TheMarkChristie/NevermoreIPTV/releases/tag/$tag',
  'body': 'notes',
  'assets':
      assets ??
      [
        {'name': 'notes.txt', 'size': 3, 'browser_download_url': 'https://example.org/notes.txt'},
        {'name': 'NevermoreIPTV-0.7.5-public.apk', 'size': 5, 'browser_download_url': 'https://example.org/a.apk'},
      ],
};

void main() {
  group('release json', () {
    test('the APK asset is taken from a tagged release; drafts and odd tags are not', () {
      final r = releaseFromJson(_release('v0.7.5'))!;
      expect(r.version, '0.7.5');
      expect(r.apkUrl, 'https://example.org/a.apk');
      expect(r.apkSize, 5);
      expect(releaseFromJson(_release('v0.7.5', draft: true)), isNull);
      expect(releaseFromJson(_release('nightly')), isNull);
      expect(releaseFromJson(_release('v0.7.5', assets: [])), isNull);
      expect(
        releaseFromJson(
          _release(
            'v0.7.5',
            assets: [
              {'name': 'x.apk', 'size': 1, 'browser_download_url': 'http://example.org/x.apk'},
            ],
          ),
        ),
        isNull,
        reason: 'plain http only for a local check',
      );
    });

    test('versions compare by number', () {
      expect(compareVersions('0.7.10', '0.7.9'), greaterThan(0));
      expect(compareVersions('0.7.4+19', '0.7.4'), 0);
      expect(compareVersions('1.0', '0.9.9'), greaterThan(0));
      expect(compareVersions('0.7.4', '0.7.4.1'), lessThan(0));
    });
  });

  group('github', () {
    test('no release yet is not an error; a refusal is', () async {
      final none = MockClient((_) async => http.Response('{"message":"Not Found"}', 404));
      expect(await fetchLatestRelease(none, api: 'https://api.example.org/latest'), isNull);
      final ok = MockClient((req) async {
        expect(req.headers['Accept'], 'application/vnd.github+json');
        return http.Response(jsonEncode(_release('v0.7.5')), 200);
      });
      expect((await fetchLatestRelease(ok, api: 'https://api.example.org/latest'))!.version, '0.7.5');
      final limited = MockClient((_) async => http.Response('rate limited', 403));
      expect(() => fetchLatestRelease(limited, api: 'https://api.example.org/latest'), throwsA(isA<HttpException>()));
    });
  });

  group('daily check', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nevermore_stamp'));
    tearDown(() => tmp.deleteSync(recursive: true));

    Updater make(http.Client client) => Updater(
      current: '0.7.5',
      cacheDir: () async => tmp,
      stampFile: () async => File('${tmp.path}${Platform.pathSeparator}stamp.json'),
      client: client,
    );

    test('a recent answer stands without asking GitHub; an old one is asked again', () async {
      final stamp = File('${tmp.path}${Platform.pathSeparator}stamp.json');
      const newer = Release(version: '9.9.9', apkUrl: 'https://example.org/a.apk', apkSize: 1, notes: '', pageUrl: '');
      stamp.writeAsStringSync(jsonEncode({'checked': DateTime.now().toIso8601String(), 'release': newer.toStored()}));
      final silent = make(MockClient((_) async => throw StateError('GitHub was asked')));
      await silent.checkIfDue();
      expect(silent.state, UpdateState.available);
      expect(silent.latest?.version, '9.9.9');
      expect(silent.newer, isTrue);

      stamp.writeAsStringSync(
        jsonEncode({'checked': DateTime.now().subtract(const Duration(days: 2)).toIso8601String(), 'release': null}),
      );
      var asked = 0;
      final again = make(
        MockClient((_) async {
          asked++;
          return http.Response('{"message":"Not Found"}', 404);
        }),
      );
      await again.checkIfDue();
      expect(asked, 1);
      expect(again.state, UpdateState.upToDate);
      expect(again.latest, isNull);
      expect(jsonDecode(stamp.readAsStringSync())['release'], isNull);
    });
  });

  group('download', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('nevermore_upd'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('the APK lands whole, with progress; a short one is refused and leaves nothing', () async {
      final bytes = List<int>.generate(5, (i) => i);
      final client = MockClient.streaming(
        (req, body) async =>
            http.StreamedResponse(Stream.fromIterable([bytes.sublist(0, 2), bytes.sublist(2)]), 200, contentLength: 5),
      );
      const r = Release(version: '0.7.5', apkUrl: 'https://example.org/a.apk', apkSize: 5, notes: '', pageUrl: '');
      final seen = <int>[];
      final f = await downloadRelease(client, r, tmp, progress: (got, total) => seen.add(got));
      expect(f.path, endsWith('NevermoreIPTV-0.7.5.apk'));
      expect(f.readAsBytesSync(), bytes);
      expect(seen, [2, 5]);
      const bigger = Release(version: '0.7.6', apkUrl: 'https://example.org/b.apk', apkSize: 9, notes: '', pageUrl: '');
      await expectLater(downloadRelease(client, bigger, tmp), throwsA(isA<HttpException>()));
      expect(tmp.listSync().where((e) => e.path.contains('0.7.6')), isEmpty);
    });
  });
}
