import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/copies.dart';
import 'package:nevermore_iptv/core/model.dart';
import 'package:nevermore_iptv/core/player_state.dart';

Channel ch(String key, String name, [String group = 'g']) => Channel(key, name, group, 0);

void main() {
  final catalog = Catalog(
    groups: [const Group('g', 'UK-SPORTS', 0), const Group('u', 'UK 4K', 1)],
    channels: [
      ch('1', 'SKY SPORTS MAIN EVENT HD'),
      ch('2', 'SKY SPORTS MAIN EVENT 4K', 'u'),
      ch('3', 'SKY SPORTS MAIN EVENT HEVC'),
      ch('4', 'SKY SPORTS MAIN EVENT'),
      ch('5', 'SKY SPORTS FOOTBALL HD'),
      ch('6', 'UK: Sky Sports Main Event FHD'),
    ],
  );

  test('quality words rank 4K first and none last', () {
    expect(qualityRank('X 4K'), 0);
    expect(qualityRank('X UHD'), 0);
    expect(qualityRank('X HEVC'), 1);
    expect(qualityRank('X FHD'), 2);
    expect(qualityRank('X HD'), 3);
    expect(qualityRank('X SD'), 4);
    expect(qualityRank('X'), 5);
    expect(qualityWord('Sky Sports F1 4k'), '4K');
    expect(qualityWord('X'), '');
  });

  test('copies are the same channel under other quality words, best first, any group or prefix', () {
    final copies = copiesOf(catalog, catalog.channels[0]);
    expect([for (final c in copies) c.key], ['2', '3', '6', '4']);
  });

  test('the ring after a failed copy goes down the order and round', () {
    final hd = catalog.channels[0];
    expect([for (final c in copiesAfter(catalog, hd, hd)) c.key], ['4', '2', '3', '6']);
    final hevc = catalog.channels[2];
    expect([for (final c in copiesAfter(catalog, hd, hevc)) c.key], ['6', '1', '4', '2']);
    expect(copiesAfter(catalog, catalog.channels[4], catalog.channels[4]), isEmpty);
  });

  test('the small picture takes the SD copy, else HD, else FHD, else HEVC, else the channel', () {
    expect(smallerCopy(catalog, catalog.channels[1]).key, '1'); // 4K chosen: the HD copy
    expect(smallerCopy(catalog, catalog.channels[4]).key, '5'); // no copies: itself
    final sd = Catalog(channels: [ch('a', 'X 4K'), ch('b', 'X SD'), ch('c', 'X HD')]);
    expect(smallerCopy(sd, sd.channels[0]).key, 'b');
    final hevc = Catalog(channels: [ch('a', 'X 4K'), ch('b', 'X HEVC')]);
    expect(smallerCopy(hevc, hevc.channels[0]).key, 'b');
  });

  test('a stall is 20 s without the position moving while playing', () {
    expect(stalled(playing: true, sinceMove: const Duration(seconds: 20)), isTrue);
    expect(stalled(playing: true, sinceMove: const Duration(seconds: 19)), isFalse);
    expect(stalled(playing: false, sinceMove: const Duration(minutes: 5)), isFalse);
  });
}
