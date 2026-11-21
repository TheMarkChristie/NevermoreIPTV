// The Web category's sites and their icons. Run: flutter test
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/guide.dart';
import 'package:nevermore_iptv/core/model.dart';
import 'package:nevermore_iptv/core/presets.dart';
import 'package:nevermore_iptv/core/web.dart';

void main() {
  test('a site reopens only at one of its own pages', () {
    const site = 'https://www.clubtv.example/no';
    expect(onSite(site, 'https://www.clubtv.example/no/login'), isTrue);
    expect(onSite(site, 'https://clubtv.example/watch/123'), isTrue);
    expect(onSite(site, 'https://accounts.example.com/signin?back=clubtv.example'), isFalse);
    expect(onSite(site, 'about:blank'), isFalse);
    expect(onSite('not a site', 'https://clubtv.example/'), isFalse);
  });

  test('sites are read from the house file; no address, no site; no name, the host', () {
    final sites = sitesFromJson({
      'sites': [
        {'name': 'Club TV', 'url': 'https://tv.example.com/'},
        {'url': 'https://www.other.example/no'},
        {'name': 'Not a web address', 'url': 'ftp://x'},
        {'name': 'No address'},
      ],
    });
    expect([for (final s in sites) s.name], ['Club TV', 'www.other.example']);
    expect(sites.first.url, 'https://tv.example.com/');
    expect(sitesFromJson(null), isEmpty);
  });

  test('the best icon is the largest a page names; none named, none', () {
    final page = Uri.parse('https://www.example.com/no');
    const html = '''
      <link rel="icon" type="image/png" sizes="16x16" href="/favicon/favicon-16x16.png">
      <link rel="apple-touch-icon" href="https://images.example.com/apple-touch-icon.png">
      <link rel="mask-icon" href="/safari.svg" sizes="512x512">
      <link rel='icon' sizes='32x32' href='favicon-32.png'>''';
    expect(namedIconUrl(html, page).toString(), 'https://images.example.com/apple-touch-icon.png');
    expect(
      namedIconUrl('<link rel="shortcut icon" href="icons/f.png">', page).toString(),
      'https://www.example.com/icons/f.png',
    );
    expect(namedIconUrl('<title>Loading</title>', page), isNull);
  });

  // The sites' guide (21 Nov 2026): a house hosts an XMLTV file naming each site by host, display name = the site's name
  group('the Web guide', () {
    final sites = [
      const WebSite('House TV', 'http://127.0.0.1:47390/'), // a built-in page: matched by its name
      const WebSite('Club TV', 'https://www.tv.example.com/no'), // matched by its host
      const WebSite('Other TV', 'https://other.example/'), // not in the guide
    ];

    test('a site\'s guide id is its host without www', () {
      expect(siteGuideId('https://www.tv.example.com/no'), 'tv.example.com');
      expect(siteGuideId('https://Club.Example/'), 'club.example');
      expect(siteGuideId('not an address'), isNull);
      expect([for (final ch in webCategory(sites, const {})!.channels) ch.channel.guideId],
          ['127.0.0.1', 'tv.example.com', 'other.example']);
    });

    test('the house file names it; anything but a web address is none', () {
      expect(webGuideFromJson({'web_guide': 'https://house.example/myteams/guide.xml'}), 'https://house.example/myteams/guide.xml');
      expect(webGuideFromJson({'web_guide': 'ftp://x'}), '');
      expect(webGuideFromJson({'sites': []}), '');
      expect(webGuideFromJson(null), '');
    });

    test('its programme names reach the sites, by host or by name', () async {
      final dir = await Directory.systemTemp.createTemp('webguide');
      addTearDown(() => dir.delete(recursive: true));
      const now = 1795262400; // 21 Nov 2026, 12:00 UTC
      String stamp(int t) {
        final d = DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true);
        String two(int v) => v.toString().padLeft(2, '0');
        return '${d.year}${two(d.month)}${two(d.day)}${two(d.hour)}${two(d.minute)}00 +0000';
      }

      final xml = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n')
        ..writeln('<channel id="house.example"><display-name>House TV</display-name></channel>')
        ..writeln('<channel id="tv.example.com"><display-name>Something else</display-name></channel>');
      for (final (id, title) in [('house.example', 'My Teams'), ('tv.example.com', 'The Club &amp; co')]) {
        for (var h = -2; h < 4; h++) {
          final t = now + h * 3600;
          xml.writeln('<programme start="${stamp(t)}" stop="${stamp(t + 3600)}" channel="$id"><title>$title</title></programme>');
        }
      }
      xml.writeln('</tv>');
      final file = File('${dir.path}${Platform.pathSeparator}web.xml')..writeAsStringSync(xml.toString());
      final channels = [for (final ch in webCategory(sites, const {})!.channels) ch.channel];
      final build = await buildGuide([('Web guide', file.path)], [GuideChannels(webSourceId, channels, Selection())], now);
      expect(build.matches['web:http://127.0.0.1:47390/']?.$3, 'name');
      expect(build.matches['web:https://www.tv.example.com/no']?.$3, 'id');
      expect(build.matches.containsKey('web:https://other.example/'), isFalse);
      final club = build.programmes['web:https://www.tv.example.com/no']!;
      expect(club.first.title, 'The Club & co');
      expect(club.any((p) => p.start <= now && now < p.stop), isTrue);
      expect(build.programmes['web:http://127.0.0.1:47390/']!.first.title, 'My Teams');
    });
  });
}
