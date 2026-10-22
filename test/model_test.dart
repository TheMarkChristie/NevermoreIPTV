// The catalogue, the selection, names and guide matching, and now/next: the IPTV Player's tests/test_model.py, ported.
// Run: flutter test
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/m3u.dart';
import 'package:nevermore_iptv/core/model.dart';
import 'package:nevermore_iptv/core/offthread.dart';

const free =
    '''#EXTM3U x-tvg-url="https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz, https://x/ALL_SOURCES1.xml.gz"
#EXTINF:-1 tvg-name="BBC One" tvg-logo="https://up/bbc1.png" tvg-id="BBCOne.uk" tvg-chno="1" tvg-country="GB" group-title="UK",BBC One Ⓖ
https://vs-hls-pushb-uk-live.akamaized.net/x=4/i=urn:bbc:pips:service:bbc_one_yorks/iptv_hd_abr_v1.m3u8
#EXTINF:-1 tvg-id="NRK1.no" group-title="Norway",NRK1 Ⓖ
https://nrk-live-no.akamaized.net/nrk1/muxed.m3u8
#EXTINF:-1 tvg-id="Kanal10Norway.no" group-title="Norway",Kanal 10 Norge Ⓨ
https://www.youtube.com/c/Kanal10Norge/live
#EXTINF:-1 group-title="Denmark",TV 2/Fyn
https://cdn.jwplayer.com/live/broadcast/igp9r9oc.mpd
#EXTINF:-1 group-title="Ireland",Today FM
#EXTVLCOPT:http-user-agent=Radio/1.0
https://live-bauerie.sharp-stream.com/TDAAC
#EXTINF:-1 group-title="UK",BBC One Ⓖ
https://other/bbc1.m3u8
''';

Catalog _cat() => Catalog(
  groups: [const Group('uk', 'UK', 0), const Group('no', 'Norway', 1)],
  channels: [
    const Channel('a', 'UK: BBC ONE', 'uk', 0),
    const Channel('b', 'UK: BBC 2', 'uk', 1),
    const Channel('c', 'NRK1', 'no', 2),
    const Channel('d', 'NRK2', 'no', 3),
  ],
);

List<String> _keys(Catalog cat, Selection sel) => [for (final c in shownChannels(cat, sel)) c.key];

void main() {
  test('m3u parse and header', () {
    final entries = parseM3u(free);
    expect([for (final e in entries) e.name].take(2), ['BBC One Ⓖ', 'NRK1 Ⓖ']);
    expect(entries[0].tvgId, 'BBCOne.uk');
    expect(entries[0].group, 'UK');
    expect(entries[0].chno, '1');
    expect(entries[4].userAgent, 'Radio/1.0');
    expect(headerGuides(free), [
      'https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz',
      'https://x/ALL_SOURCES1.xml.gz',
    ]);
  });

  test('m3u comma inside quotes', () {
    final e = parseM3u(
      '#EXTM3U\n#EXTINF:-1 tvg-name="A, B" group-title="News, World",Name, with comma\nhttp://a/b.m3u8\n',
    ).first;
    expect(e.group, 'News, World');
    expect(e.name, 'Name, with comma');
  });

  test('catalogue from m3u skips unplayable and dedupes keys', () {
    final cat = catalogFromM3u(parseM3u(free), headerGuides(free));
    expect(cat.skipped, 2); // YouTube and DASH
    expect([for (final g in cat.groups) g.name], ['UK', 'Norway', 'Ireland']);
    final keys = [for (final c in cat.channels) c.key];
    expect(keys.first, 'uk/bbc-one');
    expect(keys.last, 'uk/bbc-one~2');
    expect(keys.toSet().length, keys.length);
  });

  test('catalogue from xtream', () {
    final cats = [
      {'category_id': '7', 'category_name': 'UNITED KINGDOM'},
      {'category_id': '8', 'category_name': 'UK-SPORTS'},
    ];
    final streams = <Map<String, dynamic>>[
      {
        'stream_id': 1000931,
        'name': 'UK: BBC 2',
        'category_id': '7',
        'epg_channel_id': 'BBCTwo.uk',
        'num': 12,
        'stream_icon': 'http://logo/b2.png',
        'stream_type': 'live',
      },
      {'stream_id': 5, 'name': 'UK: SKY SPORTS F1', 'category_id': '8', 'epg_channel_id': '', 'stream_type': 'live'},
      {'stream_id': 6, 'name': 'Orphan', 'category_id': '99', 'stream_type': 'live'},
      {'stream_id': 7, 'name': 'A film', 'category_id': '7', 'stream_type': 'movie'},
    ];
    final cat = catalogFromXtream(cats, streams);
    expect([for (final c in cat.channels) c.key], ['1000931', '5', '6']);
    expect(cat.channels[0].guideId, 'BBCTwo.uk');
    expect(cat.channels[0].number, 12);
    expect(cat.channels[1].guideId, isNull);
    expect(cat.groups.last.id, '_other');
    expect(cat.channels[2].group, '_other');
  });

  test('catalogue survives a JSON round trip', () {
    final cat = catalogFromM3u(parseM3u(free), headerGuides(free));
    final back = Catalog.fromJson(cat.toJson());
    expect([for (final c in back.channels) c.key], [for (final c in cat.channels) c.key]);
    expect(back.channels.last.url, 'https://other/bbc1.m3u8');
    expect(back.channels[2].userAgent, 'Radio/1.0');
    expect(back.guideUrls, cat.guideUrls);
  });

  test('selection: group tick, untick and new channels', () {
    final cat = _cat();
    var sel = applyChanges(Selection(), [
      {'group': 'uk', 'on': true},
    ]);
    expect(_keys(cat, sel), ['a', 'b']);
    sel = applyChanges(sel, [
      {'channel': 'b', 'on': false},
      {'channel': 'c', 'on': true},
    ]);
    expect(_keys(cat, sel), ['a', 'c']);
    // the provider adds a channel to the ticked group: it shows by itself
    cat.channels.add(const Channel('e', 'UK: BBC FOUR', 'uk', 4));
    expect(_keys(cat, sel), ['a', 'e', 'c']);
    // follow the group again
    sel = applyChanges(sel, [
      {'channel': 'b', 'on': null},
    ]);
    expect(_keys(cat, sel), contains('b'));
    sel = applyChanges(sel, [
      {'group': 'uk', 'on': false},
    ]);
    expect(_keys(cat, sel), ['c']);
  });

  test('order and rename', () {
    final cat = _cat();
    var sel = applyChanges(
      Selection(),
      [
        {'group': 'uk', 'on': true},
        {'group': 'no', 'on': true},
      ],
      groupOrder: ['no', 'uk'],
    );
    expect(_keys(cat, sel), ['c', 'd', 'a', 'b']);
    sel = applyChanges(sel, [
      {
        'order': ['d', 'c'],
      },
    ]);
    sel = applyChanges(sel, [
      {
        'order': ['b', 'a'],
      },
    ]);
    expect(_keys(cat, sel), ['d', 'c', 'b', 'a']); // the Norway order survived
    sel = applyChanges(sel, [
      {'channel': 'a', 'name': 'BBC One Scotland'},
    ]);
    expect(displayName(cat.channel('a')!, sel), 'BBC One Scotland');
    sel = applyChanges(sel, [
      {'channel': 'a', 'name': ''},
    ]);
    expect(displayName(cat.channel('a')!, sel), 'UK: BBC ONE');
    expect(sel.channels.containsKey('a'), isFalse);
  });

  test('selection survives a JSON round trip and tolerates old data', () {
    final sel = applyChanges(
      Selection(),
      [
        {'group': 'uk', 'on': true},
        {'channel': 'b', 'on': false, 'name': 'Two'},
      ],
      groupOrder: ['no'],
    );
    final back = Selection.fromJson(sel.toJson());
    expect(back.groups, {'uk': true});
    expect(back.channels['b'], {'on': false, 'name': 'Two'});
    expect(back.groupOrder, ['no']);
    expect(
      Selection.fromJson({
        'groups': {'uk': true},
      }).groupNames,
      isEmpty,
    );
    expect(Selection.fromJson('rubbish').groups, isEmpty);
  });

  test('names', () {
    expect(tidyName('UK: BBC 2'), 'BBC 2');
    expect(tidyName('US-S: BIG TEN NETWORK BTN'), 'BIG TEN NETWORK BTN');
    expect(tidyName('NRK1 Ⓖ'), 'NRK1');
    expect(normName('UK: BBC TWO FHD'), 'bbc2');
    expect(normName('BBC Two HD'), 'bbc2');
    expect(normName('BBC 2'), 'bbc2');
    expect(normName('Sky Sports+ HD'), 'skysportsplus');
    expect(normName('Channel 4 +1'), isNot(normName('Channel 4')));
    expect(normName('TV 2 Østlandet'), 'tv2ostlandet');
    // epgshare01's Norway and Sweden files name channels their own way
    expect(normName('NRK1 Norway (NO,NO)'), normName('NRK1'));
    expect(normName('NRK Super Norway (NO,NO)'), 'nrksuper');
    expect(normName('BBC 1 (GB,EN)'), 'bbc1');
    expect(normName("6'eren Denmark (DK,DA)"), '6eren');
    expect(normName('[DR1DK] DR1'), 'dr1');
    expect(normName('BBC One Scotland (GB,EN)'), 'bbc1scotland'); // a nation, not a country: kept
    expect(normName('TV Norway'), 'tvnorway'); // no "(XX,YY)" ending: nothing taken off
    expect(withoutMarks('BBC One Ⓖ'), 'BBC One');
  });

  test('match guides in order', () {
    final cat = Catalog(
      groups: [const Group('uk', 'UK', 0)],
      channels: [
        const Channel('a', 'UK: BBC ONE SCOTLAND', 'uk', 0, guideId: 'BBCOneScotland.uk'),
        const Channel('b', 'UK: BBC 2', 'uk', 1, guideId: 'Wrong.uk'),
        const Channel('c', 'UK: STV', 'uk', 2),
        const Channel('d', 'UK: Nothing', 'uk', 3),
      ],
    );
    final provider = GuideSource('Provider guide', {
      'BBCOneScotland.uk': ['BBC One Scotland'],
      'STVx.uk': ['STV'],
    });
    final freeGuide = GuideSource('epgshare01 UK1', {
      'BBC.Two.HD.uk': ['BBC Two HD'],
      'STV.HD.uk': ['STV HD'],
    });
    var sel = Selection();
    final got = matchGuides(cat.channels, sel, [provider, freeGuide]);
    expect(got['a'], (0, 'BBCOneScotland.uk', 'id'));
    expect(got['b'], (1, 'BBC.Two.HD.uk', 'name')); // its own id is in neither guide; the free one has the name
    expect(got['c'], (0, 'STVx.uk', 'name')); // the provider's guide first
    expect(got.containsKey('d'), isFalse);
    sel = applyChanges(sel, [
      {'channel': 'c', 'guide': 'epgshare01 UK1|STV.HD.uk'},
    ]);
    expect(matchGuides(cat.channels, sel, [provider, freeGuide])['c'], (1, 'STV.HD.uk', 'manual'));
    final found = searchGuideChannels([provider, freeGuide], 'bbc two');
    expect(found.first.id, 'BBC.Two.HD.uk');
    expect(found.first.source, 'epgshare01 UK1');
  });

  test('now, next and window', () {
    const progs = [Programme(100, 200, 'A'), Programme(200, 300, 'B'), Programme(300, 400, 'C')];
    var (cur, nxt) = nowNext(progs, 250);
    expect(cur!.title, 'B');
    expect(nxt!.title, 'C');
    (cur, nxt) = nowNext(progs, 50);
    expect(cur, isNull);
    expect(nxt!.title, 'A');
    expect([for (final p in window(progs, 150, 310)) p.title], ['A', 'B', 'C']);
  });

  test('work off the screen thread really runs in another isolate', () async {
    final cat = await playlistCatalog(utf8.encode(free));
    expect(cat.channels.length, 4);
    expect(cat.skipped, 2);
    await expectLater(playlistCatalog(utf8.encode('<html>not a playlist</html>')), throwsFormatException);
    final big = jsonEncode([
      for (var i = 0; i < 20000; i++) {'stream_id': i, 'name': 'Channel $i'},
    ]);
    expect(((await decodeJson(big)) as List).length, 20000);
    expect(
      jsonDecode(
        await encodeJson({
          'a': [1, 2],
        }),
      ),
      {
        'a': [1, 2],
      },
    );
  });

  test('playable addresses', () {
    expect(playableUrl('https://a/b.m3u8'), isTrue);
    expect(playableUrl('https://www.youtube.com/c/x/live'), isFalse);
    expect(playableUrl('https://cdn/x.mpd?token=1'), isFalse);
    expect(playableUrl('rtmp://a/b'), isFalse);
  });

  test('renaming a group keeps its tick', () {
    final cat = _cat();
    var sel = applyChanges(Selection(), [
      {'group': 'uk', 'on': true},
    ]);
    sel = applyChanges(sel, [
      {'group': 'uk', 'name': 'British'},
    ]);
    expect(sel.groups, {'uk': true});
    expect(groupName(cat.group('uk')!, sel), 'British');
    sel = applyChanges(sel, [
      {'group': 'uk', 'name': '  '},
    ]);
    expect(groupName(cat.group('uk')!, sel), 'UK');
    expect(sel.groupNames.containsKey('uk'), isFalse);
  });
}
