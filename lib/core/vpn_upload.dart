/// Installing a WireGuard file without the PC script: while "Add a WireGuard file" is open, the TV serves one small page
/// on the home network, at an address with a one-time code (`http://<TV>:8765/<code>`). A phone or computer opens it,
/// picks the file (or pastes its text) and sends it; the TV checks it is a WireGuard file and keeps it. Any VPN that
/// gives WireGuard files works: Proton, Mullvad, Surfshark, Windscribe, a server of your own.
///
/// Only that address answers, only while the screen is open, only with a body under 16 KB, and five wrong codes close
/// the page.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

const uploadPort = 8765;
const _maxBytes = 16 * 1024;

class UploadResult {
  const UploadResult(this.name, this.text);

  final String name;
  final String text;
}

/// The TV's address on the home network (Wi-Fi or Ethernet), or null.
Future<String?> lanAddress() async {
  final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  String? fallback;
  for (final i in interfaces) {
    for (final a in i.addresses) {
      if (a.isLoopback || a.address.startsWith('169.254.')) continue;
      final private =
          a.address.startsWith('192.168.') ||
          a.address.startsWith('10.') ||
          RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(a.address);
      // the VPN's own interface is not the home network
      if (private && !i.name.startsWith('tun') && !i.name.startsWith('nevermore')) return a.address;
      fallback ??= a.address;
    }
  }
  return fallback;
}

/// "wg-NL-FREE-3.conf" -> "wg-NL-FREE-3"; anything odd taken out.
String cleanFileName(String? raw) {
  var name = (raw ?? '').split(RegExp(r'[\\/]')).last;
  name = name.replaceAll(RegExp(r'\.conf$', caseSensitive: false), '');
  name = name.replaceAll(RegExp(r'[^A-Za-z0-9 ._#()-]'), '').trim();
  return name.length > 60 ? name.substring(0, 60) : name;
}

class VpnUploadServer {
  VpnUploadServer({required this.accept});

  /// Checks and keeps a file; null when it is kept, else why not.
  final Future<String?> Function(UploadResult result) accept;

  HttpServer? _server;
  late final String code = (100000 + Random.secure().nextInt(900000)).toString();

  /// Wrong codes per caller: five from one address close the page (a browser's own icon requests do not count).
  final Map<String, int> _wrongBy = {};
  final _received = StreamController<String>.broadcast();
  final _closed = Completer<void>();

  /// The name of each file kept, as it arrives.
  Stream<String> get received => _received.stream;

  /// Done when the page closed itself after five wrong codes, so the screen can say so instead of waiting on.
  Future<void> get closed => _closed.future;

  Future<int> start() async {
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, uploadPort);
    } on SocketException {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen(_handle, onError: (_) {});
    return _server!.port;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    await _received.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var guessed = 0;
    try {
      final path = req.uri.path;
      // browsers ask for an icon by themselves: no answer, and not a wrong code (review, 24 Oct 2026)
      if (path == '/favicon.ico' || path.startsWith('/apple-touch-icon')) {
        res.statusCode = HttpStatus.noContent;
        return;
      }
      if (path != '/$code') {
        final who = req.connectionInfo?.remoteAddress.address ?? '?';
        guessed = _wrongBy[who] = (_wrongBy[who] ?? 0) + 1;
        res.statusCode = HttpStatus.notFound;
        res.write('Not here.');
        return;
      }
      if (req.method == 'GET') {
        res.headers.contentType = ContentType.html;
        res.write(_page);
        return;
      }
      if (req.method != 'POST') {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final bytes = BytesBuilder();
      await for (final chunk in req) {
        bytes.add(chunk);
        if (bytes.length > _maxBytes) {
          res.statusCode = HttpStatus.requestEntityTooLarge;
          res.write('That is far bigger than a WireGuard file.');
          return;
        }
      }
      final name = cleanFileName(req.headers.value('x-file-name'));
      final why = await accept(UploadResult(name, utf8.decode(bytes.takeBytes(), allowMalformed: true)));
      res.headers.contentType = ContentType.text;
      if (why == null) {
        res.write('Saved on the TV${name.isEmpty ? '' : ' as $name'}. You can close this page.');
        _received.add(name);
      } else {
        res.statusCode = HttpStatus.badRequest;
        res.write(why);
      }
    } finally {
      await res.close();
      // five wrong codes from one caller: someone is guessing - the page closes (after its answer, so that answer
      // arrives whole) and the screen is told
      if (guessed >= 5) {
        unawaited(_server?.close(force: true));
        if (!_closed.isCompleted) _closed.complete();
      }
    }
  }
}

const _page = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nevermore IPTV - VPN file</title><link rel="icon" href="data:,">
<style>
  body { margin: 0; padding: 16px; font: 16px/1.5 system-ui, sans-serif; background: #101114; color: #f2f4f7; }
  main { max-width: 560px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 8px 0 4px; }
  p { color: #aab0ba; margin: 4px 0 16px; }
  label { display: block; font-weight: 600; margin: 16px 0 6px; }
  input[type=file], textarea { width: 100%; box-sizing: border-box; color: #f2f4f7; background: #1c1f25;
    border: 2px solid #3a4150; border-radius: 8px; padding: 10px; font: 14px ui-monospace, monospace; }
  textarea { min-height: 160px; }
  button { margin-top: 16px; width: 100%; padding: 14px; font: 600 17px system-ui, sans-serif; color: #101114;
    background: #a9beda; border: 0; border-radius: 8px; }
  button:focus-visible, input:focus-visible, textarea:focus-visible { outline: 3px solid #ffffff; outline-offset: 2px; }
  #result { margin-top: 16px; font-weight: 600; }
</style></head>
<body><main>
  <h1>Send a WireGuard file to the TV</h1>
  <p>From any VPN that gives WireGuard files (Proton, Mullvad, Surfshark, Windscribe...): a server outside the UK.</p>
  <label for="file">The file (.conf)</label>
  <input id="file" type="file" accept=".conf,text/plain">
  <label for="text">Or paste its text</label>
  <textarea id="text" spellcheck="false" placeholder="[Interface]&#10;PrivateKey = ...&#10;&#10;[Peer]&#10;Endpoint = ..."></textarea>
  <button id="send" type="button">Send to the TV</button>
  <div id="result" role="status" aria-live="polite"></div>
</main>
<script>
  let fileName = '';
  document.getElementById('file').addEventListener('change', async (e) => {
    const f = e.target.files[0];
    if (!f) return;
    fileName = f.name;
    document.getElementById('text').value = await f.text();
  });
  document.getElementById('send').addEventListener('click', async () => {
    const out = document.getElementById('result');
    out.textContent = 'Sending...';
    try {
      const r = await fetch(location.pathname, { method: 'POST', body: document.getElementById('text').value,
        headers: { 'Content-Type': 'text/plain; charset=utf-8', 'X-File-Name': fileName } });
      out.textContent = await r.text();
    } catch (err) {
      out.textContent = 'The TV did not answer. Is "Add a WireGuard file" still open on it?';
    }
  });
</script>
</body></html>''';
