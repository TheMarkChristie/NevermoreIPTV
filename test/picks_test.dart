import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/picks.dart';
import 'package:nevermore_iptv/core/site_logins.dart';

void main() {
  test('a picks file is known by its mark and its sources', () {
    expect(picksProblem({'nevermore_picks': 1, 'sources': []}), isNull);
    expect(
      picksProblem({
        'nevermore_picks': 1,
        'sources': [
          {'id': 'a', 'kind': 'm3u', 'url': 'http://x/list.m3u'},
        ],
      }),
      isNull,
    );
    expect(picksProblem('text'), 'Not a picks file.');
    expect(picksProblem({'sources': []}), 'Not a Nevermore IPTV picks file.');
    expect(picksProblem({'nevermore_picks': 2, 'sources': []}), contains('newer version'));
    expect(picksProblem({'nevermore_picks': 1}), 'The file has no sources.');
    expect(
      picksProblem({
        'nevermore_picks': 1,
        'sources': [
          {'id': 'a'},
        ],
      }),
      'A source in the file is not readable.',
    );
  });

  test('a site login is kept by the host, www. aside', () {
    expect(siteHost('https://www.clubtv.example/no/login'), 'clubtv.example');
    expect(siteHost('https://clubtv.example/'), 'clubtv.example');
    expect(siteHost('not a url'), '');
  });
}
