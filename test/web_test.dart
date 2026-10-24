// The Web category's sites and their icons. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/presets.dart';
import 'package:nevermore_iptv/core/web.dart';

void main() {
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
}
