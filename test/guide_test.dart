// The guide build (in another isolate, as on the TV) and the guide file rules. Run: flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/guide.dart';
import 'package:nevermore_iptv/core/model.dart';
import 'package:nevermore_iptv/core/xmltv.dart';

const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="BBCOneScotland.uk"><display-name>BBC One Scotland</display-name></channel>
  <channel id="STV.uk"><display-name>STV &amp; more</display-name></channel>
  <programme start="20261019180000 +0100" stop="20261019183000 +0100" channel="BBCOneScotland.uk"><title>Reporting Scotland</title></programme>
  <programme channel="BBCOneScotland.uk" stop="20261019190000 +0100" start="20261019183000 +0100"><title>The One Show</title></programme>
  <programme start="20261019170000 +0000" stop="20261019180000 +0000" channel="STV.uk"><title>STV News</title></programme>
  <programme start="20261023170000 +0000" stop="20261023180000 +0000" channel="STV.uk"><title>Days later</title></programme>
</tv>
''';

void main() {
  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('nevermore_guide'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('the guide is built in another isolate: matches by id and by name, programmes in the window', () async {
    final path = '${tmp.path}${Platform.pathSeparator}g.dat';
    File(path).writeAsBytesSync(gzip.encode(utf8.encode(xml)));
    final now = parseXmltvTime('20261019173000 +0000')!;
    final channels = [
      const Channel('a', 'UK: BBC ONE SCOTLAND', 'uk', 0, guideId: 'BBCOneScotland.uk'),
      const Channel('b', 'UK: STV & MORE', 'uk', 1),
      const Channel('c', 'UK: NOTHING', 'uk', 2),
    ];
    final build = await buildGuide([('Provider guide', path)], [GuideChannels('s1', channels, Selection())], now);
    expect(build.matches['s1:a'], (0, 'BBCOneScotland.uk', 'id'));
    expect(build.matches['s1:b'], (0, 'STV.uk', 'name'));
    expect(build.matches.containsKey('s1:c'), isFalse);
    expect([for (final p in build.programmes['s1:a']!) p.title], ['Reporting Scotland', 'The One Show']);
    expect([for (final p in build.programmes['s1:b']!) p.title], ['STV News']); // "Days later" is past 36 hours
    expect(build.names.single.length, 2);
    expect(build.errors.single, isNull);
  });

  test('an unreadable file is reported, not read as empty', () async {
    final path = '${tmp.path}${Platform.pathSeparator}bad.dat';
    File(path).writeAsStringSync('{"error": "not xml"}');
    final build = await buildGuide([('Broken', path)], const [], 0);
    expect(build.errors.single, startsWith('unreadable'));
  });

  test('guide file names and the header rule', () {
    expect(guideLabelFor('https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz'), 'epgshare01 UK1');
    expect(guideLabelFor('https://example.com/guide.xml'), 'guide');
    final five = List.generate(5, (i) => 'https://g/$i.xml');
    expect(usableHeaderGuides(five), five);
    expect(usableHeaderGuides([...five, 'https://g/6.xml']), isEmpty);
    expect(usableHeaderGuides(['https://g/ALL_SOURCES1.xml.gz', 'https://g/UK1.xml.gz']), ['https://g/UK1.xml.gz']);
    expect(fileKey('https://a'), fileKey('https://a'));
    expect(fileKey('https://a'), isNot(fileKey('https://b')));
    expect(fileKey('https://a').length, 16);
  });
}
