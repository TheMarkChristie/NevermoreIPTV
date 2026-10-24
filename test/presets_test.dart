// Presets: reading presets.json, finding the source, and the selection a preset gives. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/model.dart';
import 'package:nevermore_iptv/core/presets.dart';
import 'package:nevermore_iptv/core/sources.dart';

final catalog = Catalog(
  groups: const [Group('7', 'NHL', 0), Group('20', 'UK-SPORTS', 1), Group('8', 'PPV-2', 2), Group('339', 'PPV-1', 3)],
  channels: const [
    Channel('1', 'US-S: NHL NETWORK', '7', 0),
    Channel('2', 'NHL: SEATTLE KRAKEN', '7', 1),
    Channel('3', 'NHL: BOSTON BRUINS', '7', 2),
    Channel('4', 'UK: SKY SPORTS MAIN EVENT', '20', 3),
    Channel('5', 'UK: TNT SPORTS 1', '20', 4),
    Channel('6', 'PPV 1', '339', 5),
    Channel('7', 'PPV 2', '8', 6),
  ],
);

final preset = presetsFromJson({
  'presets': [
    {
      'code': '12345678',
      'name': 'My provider',
      'server': 'host.example:8080',
      'groups': [
        {
          'group': 'nhl',
          'channels': ['Network', 'seattle kraken', 'winnipeg'],
        },
        {'group': 'UK-SPORTS', 'name': 'UK Sport', 'all': true},
        {'group': 'PPV-1', 'name': 'PPV', 'all': true},
        {'group': 'PPV-2', 'name': 'PPV', 'all': true},
        {'group': 'NFL', 'all': true},
      ],
    },
    {'name': 'no code, left out'},
  ],
}).single;

void main() {
  test('presets.json is read; a preset without a code is left out', () {
    expect(preset.code, '12345678');
    expect(preset.server, 'http://host.example:8080');
    expect(preset.groups.first.channels, ['network', 'seattle kraken', 'winnipeg']);
    expect(presetsFromJson('not json'), isEmpty);
  });

  test('a preset ticks what it names, renames and orders the groups, and says what is missing', () {
    final r = applyPreset(catalog, preset);
    final shown = [for (final c in shownChannels(catalog, r.selection)) c.name];
    expect(shown, [
      'US-S: NHL NETWORK',
      'NHL: SEATTLE KRAKEN',
      'UK: SKY SPORTS MAIN EVENT',
      'UK: TNT SPORTS 1',
      'PPV 1',
      'PPV 2',
    ]);
    expect(r.shown, 6);
    expect(r.selection.groups, {'20': true, '339': true, '8': true});
    expect(r.selection.groupNames, {'20': 'UK Sport', '339': 'PPV', '8': 'PPV'});
    expect(r.missing, ['nhl: winnipeg', 'NFL']);
  });

  test('the source is the Xtream login on the preset\'s server, else the one with its name', () {
    Source s(String id, String name, String url, {SourceKind kind = SourceKind.xtream}) =>
        Source(id: id, kind: kind, name: name, url: url, username: 'u', password: 'p', guideUrl: '', output: 'ts');
    final free = s('a', 'Free-TV', 'https://raw.githubusercontent.com/x.m3u8', kind: SourceKind.m3u);
    expect(
      presetSource(preset, [free, s('b', 'Other', 'http://other:80'), s('c', 'Mine', 'http://HOST.example:8080')])?.id,
      'c',
    );
    expect(presetSource(preset, [free, s('d', 'my provider', 'http://moved:80')])?.id, 'd');
    expect(presetSource(preset, [free]), isNull);
  });
}
