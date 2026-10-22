// The one-time page a phone sends a WireGuard file to. Run: flutter test
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/vpn.dart';
import 'package:nevermore_iptv/core/vpn_upload.dart';

const conf =
    '[Interface]\nPrivateKey = aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI=\nAddress = 10.2.0.2/32\n\n'
    '[Peer]\nPublicKey = d29ybGQtd29ybGQtd29ybGQtd29ybGQtd29ybGQtMTI=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 203.0.113.7:51820\n';

Future<(int, String)> send(String method, int port, String path, {String? body, String? name}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    if (name != null) req.headers.set('X-File-Name', name);
    if (body != null) req.write(body);
    final res = await req.close();
    return (res.statusCode, await res.transform(utf8.decoder).join());
  } finally {
    client.close();
  }
}

void main() {
  test('only the one-time address answers; a WireGuard file is kept, anything else turned away', () async {
    final kept = <UploadResult>[];
    final server = VpnUploadServer(
      accept: (r) async {
        if (VpnSettings.parse(r.name, r.text) == null) return 'not a WireGuard file';
        kept.add(r);
        return null;
      },
    );
    final port = await server.start();
    final names = <String>[];
    final sub = server.received.listen(names.add);

    expect((await send('GET', port, '/000000')).$1, 404);
    final page = await send('GET', port, '/${server.code}');
    expect(page.$1, 200);
    expect(page.$2, contains('Send a WireGuard file to the TV'));

    final bad = await send('POST', port, '/${server.code}', body: 'hello', name: 'x.conf');
    expect(bad.$1, 400);
    expect(kept, isEmpty);

    final good = await send('POST', port, '/${server.code}', body: conf, name: r'C:\Downloads\wg-NL-FREE-3.conf');
    expect(good.$1, 200);
    expect(good.$2, contains('wg-NL-FREE-3'));
    expect(kept.single.name, 'wg-NL-FREE-3');
    expect(kept.single.text, conf);
    await Future<void>.delayed(Duration.zero);
    expect(names, ['wg-NL-FREE-3']);

    await sub.cancel();
    await server.stop();
  });

  test('five wrong codes close the page', () async {
    final server = VpnUploadServer(accept: (_) async => null);
    final port = await server.start();
    for (var i = 0; i < 5; i++) {
      await send('GET', port, '/wrong$i');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await expectLater(send('GET', port, '/${server.code}'), throwsA(isA<SocketException>()));
    await server.stop();
  });

  test('file names are cleaned', () {
    expect(cleanFileName(r'C:\x\wg-US-FREE#12.conf'), 'wg-US-FREE#12');
    expect(cleanFileName('../../evil<script>.conf'), 'evilscript');
    expect(cleanFileName(null), '');
  });
}
