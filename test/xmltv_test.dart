// The XMLTV reader: the IPTV Player's tests/test_guide_files.py (reader part), ported. Run: flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/xmltv.dart';

const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv generator-info-name="test">
  <channel id="BBCOneScotland.uk"><display-name>BBC One Scotland</display-name><display-name lang="gd">BBC Aon</display-name></channel>
  <channel id="STV.uk"><display-name>STV &amp; more</display-name><icon src="x"/></channel>
  <channel id="Empty.uk"/>
  <programme start="20261019180000 +0100" stop="20261019183000 +0100" channel="BBCOneScotland.uk"><title lang="en">Reporting Scotland</title><desc>News &amp; weather.</desc><category>News</category></programme>
  <programme channel="BBCOneScotland.uk" stop="20261019190000 +0100" start="20261019183000 +0100"><title>The One Show</title><sub-title>Monday</sub-title></programme>
  <programme start="20261019170000 +0000" stop="20261019180000 +0000" channel="STV.uk"><title>STV News</title></programme>
  <programme start="20261020170000 +0000" stop="20261020180000 +0000" channel="STV.uk"><title>Too late</title></programme>
  <programme start="20261019170000 +0000" stop="20261019180000 +0000" channel="Other.uk"><title>Not wanted</title></programme>
  <programme start="20261019180000 +0000" channel="STV.uk"><title>No stop</title></programme>
</tv>
''';

late Directory tmp;

String _write(String name, List<int> bytes) {
  final f = File('${tmp.path}${Platform.pathSeparator}$name')..writeAsBytesSync(bytes);
  return f.path;
}

void main() {
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('nevermore_xmltv'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('time', () {
    expect(parseXmltvTime('20261019180000 +0100'), parseXmltvTime('20261019170000 +0000'));
    expect(parseXmltvTime('20261019170000'), parseXmltvTime('20261019170000 +0000'));
    expect(parseXmltvTime('rubbish'), isNull);
  });

  test('channels stop at the first programme, plain and gzip', () async {
    for (final gz in [false, true]) {
      final path = _write(gz ? 'g.xml.gz' : 'g.xml', gz ? gzip.encode(utf8.encode(xml)) : utf8.encode(xml));
      expect(await readXmltvChannels(path), {
        'BBCOneScotland.uk': ['BBC One Scotland', 'BBC Aon'],
        'STV.uk': ['STV & more'],
        'Empty.uk': <String>[],
      });
    }
  });

  test('programmes: window, attribute order, elements split across reads', () async {
    final path = _write('g2.xml.gz', gzip.encode(utf8.encode(xml)));
    final start = parseXmltvTime('20261019160000 +0000')!;
    final end = parseXmltvTime('20261019200000 +0000')!;
    final got = await readXmltvProgrammes(path, {'BBCOneScotland.uk', 'STV.uk'}, start, end, descChars: 5, rechunk: 97);
    expect([for (final p in got['BBCOneScotland.uk']!) p.title], ['Reporting Scotland', 'The One Show']);
    final first = got['BBCOneScotland.uk']!.first;
    expect(first.stop - first.start, 1800);
    expect(first.category, 'News');
    expect(first.desc, 'News…');
    expect(got['BBCOneScotland.uk']![1].sub, 'Monday');
    expect([for (final p in got['STV.uk']!) p.title], ['STV News', 'No stop']);
    expect(got['STV.uk']![1].stop - got['STV.uk']![1].start, 1800); // no stop: half an hour
    expect(got.containsKey('Other.uk'), isFalse);
  });

  test('a file that is not XMLTV is refused, not read as empty', () async {
    final path = _write('zstd.xml', [0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x58, ...utf8.encode('zstd-ish')]);
    await expectLater(readXmltvChannels(path), throwsFormatException);
  });

  test('entities', () {
    expect(xmlUnescape('A &amp; B &lt;3&gt; &#39;x&#x27; &quot;q&quot;'), 'A & B <3> \'x\' "q"');
  });
}
