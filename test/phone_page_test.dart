import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/phone_page.dart';

Future<(int, String)> call(HttpClient client, String method, Uri url, [String? body]) async {
  final req = await client.openUrl(method, url);
  if (body != null) {
    req.headers.contentType = ContentType.json;
    req.write(body);
  }
  final res = await req.close();
  return (res.statusCode, await res.transform(utf8.decoder).join());
}

void main() {
  late PhoneServer server;
  late Uri base;
  final client = HttpClient();
  final posted = <Map<String, String>>[];

  setUp(() async {
    server = PhoneServer(
      title: 'Test page',
      intro: 'For the test.',
      sections: [
        PhoneSection(
          id: 'text',
          title: 'Send text',
          intro: 'Into the box.',
          form: '<textarea name="text"></textarea>',
          onPost: (fields) async {
            posted.add(fields);
            if ((fields['text'] ?? '').isEmpty) throw const PhoneRefused('Nothing to send.');
            return 'Typed ${fields['text']!.length} characters';
          },
        ),
        PhoneSection(
          id: 'picks',
          title: 'Picks',
          intro: 'Down.',
          form: '<a href="{download}">get</a>',
          onDownload: () async => ('picks.json', utf8.encode('{"nevermore_picks":1}')),
        ),
      ],
    );
    final port = await server.start();
    base = Uri.parse('http://127.0.0.1:$port/');
  });

  tearDown(() => server.stop());

  test('the page is served at the code, with its sections and the download link', () async {
    final (status, html) = await call(client, 'GET', base.resolve('/${server.code}'));
    expect(status, 200);
    expect(html, contains('Test page'));
    expect(html, contains('data-section="text"'));
    expect(html, contains('/${server.code}/picks/download'));
  });

  test('a section answers its fields, and refuses with 400', () async {
    final (ok, answer) = await call(
      client,
      'POST',
      base.resolve('/${server.code}/text'),
      jsonEncode({'text': 'hello'}),
    );
    expect(ok, 200);
    expect(answer, 'Typed 5 characters');
    expect(posted.last, {'text': 'hello'});
    final (bad, why) = await call(client, 'POST', base.resolve('/${server.code}/text'), jsonEncode({'text': ''}));
    expect(bad, 400);
    expect(why, 'Nothing to send.');
  });

  test('the download comes as a file', () async {
    final req = await client.getUrl(base.resolve('/${server.code}/picks/download'));
    final res = await req.close();
    expect(res.statusCode, 200);
    expect(res.headers.value('content-disposition'), contains('picks.json'));
    expect(await res.transform(utf8.decoder).join(), '{"nevermore_picks":1}');
  });

  test('a wrong code is not here, and five of them close the page', () async {
    for (var i = 0; i < 5; i++) {
      final (status, _) = await call(client, 'GET', base.resolve('/000000'));
      expect(status, 404);
    }
    await server.closed.timeout(const Duration(seconds: 2));
  });
}
