/// The phone page: while a screen on the TV shows it, the TV serves one small page on the home network at an address
/// with a one-time code (`http://<TV>:8765/<code>`), and a phone (or computer) that opens it can do what that screen
/// offers - type into the browser's page, sign in to a site, download this TV's picks or send a picks file (Mark, 6 Nov
/// 2026: "type on the phone", "export and restore the picks"). The same server and rules as the WireGuard page
/// (vpn_upload.dart): only that address answers, only while the screen is open, five wrong codes close it.
///
/// A screen gives the page its [PhoneSection]s: each is a form on the phone and a handler on the TV. The page posts a
/// section's fields as JSON to `/<code>/<section id>`; a download link reads `/<code>/<section id>/download`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'vpn_upload.dart' show uploadPort;

const _maxBytes = 2 * 1024 * 1024;

/// A section's answer that is a refusal: shown on the phone, with status 400.
class PhoneRefused implements Exception {
  const PhoneRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

class PhoneSection {
  const PhoneSection({
    required this.id,
    required this.title,
    required this.intro,
    required this.form,
    this.button = 'Send to the TV',
    this.onPost,
    this.onDownload,
  });

  /// In the address: 'text', 'login', 'picks'.
  final String id;
  final String title;
  final String intro;

  /// The form's HTML: inputs and textareas with a `name` (a checkbox sends "yes" or ""; a file input sends the file's
  /// text), labels, and `{download}` where a link to the section's download goes.
  final String form;
  final String button;

  /// Answers the fields posted (name -> value) with a line for the phone; throws [PhoneRefused] to refuse.
  final Future<String> Function(Map<String, String> fields)? onPost;

  /// The section's download: (file name, bytes).
  final Future<(String, List<int>)> Function()? onDownload;
}

class PhoneServer {
  PhoneServer({required this.title, required this.intro, required this.sections});

  final String title;
  final String intro;
  final List<PhoneSection> sections;

  HttpServer? _server;
  late final String code = (100000 + Random.secure().nextInt(900000)).toString();

  /// Wrong codes per caller: five from one address close the page (a browser's own icon requests do not count).
  final Map<String, int> _wrongBy = {};
  final _done = StreamController<String>.broadcast();
  final _closed = Completer<void>();

  /// What each section answered, as it happens, for the TV's screen.
  Stream<String> get done => _done.stream;

  /// Done when the page closed itself after five wrong codes.
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

  int? get port => _server?.port;

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    await _done.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    var guessed = 0;
    try {
      final path = req.uri.path;
      if (path == '/favicon.ico' || path.startsWith('/apple-touch-icon')) {
        res.statusCode = HttpStatus.noContent;
        return;
      }
      final parts = path.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty || parts.first != code) {
        final who = req.connectionInfo?.remoteAddress.address ?? '?';
        guessed = _wrongBy[who] = (_wrongBy[who] ?? 0) + 1;
        res.statusCode = HttpStatus.notFound;
        res.write('Not here.');
        return;
      }
      if (parts.length == 1) {
        if (req.method != 'GET') {
          res.statusCode = HttpStatus.methodNotAllowed;
          return;
        }
        res.headers.contentType = ContentType.html;
        res.write(pageHtml());
        return;
      }
      final section = sections.where((s) => s.id == parts[1]).firstOrNull;
      if (section == null) {
        res.statusCode = HttpStatus.notFound;
        res.write('No such section.');
        return;
      }
      if (parts.length == 3 && parts[2] == 'download' && req.method == 'GET' && section.onDownload != null) {
        final (name, bytes) = await section.onDownload!();
        res.headers.contentType = ContentType.json;
        res.headers.set('Content-Disposition', 'attachment; filename="$name"');
        res.add(bytes);
        _done.add('${section.title}: downloaded');
        return;
      }
      if (parts.length != 2 || req.method != 'POST' || section.onPost == null) {
        res.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final bytes = BytesBuilder();
      await for (final chunk in req) {
        bytes.add(chunk);
        if (bytes.length > _maxBytes) {
          res.statusCode = HttpStatus.requestEntityTooLarge;
          res.write('That is far too big.');
          return;
        }
      }
      final fields = <String, String>{};
      try {
        final decoded = jsonDecode(utf8.decode(bytes.takeBytes(), allowMalformed: true));
        if (decoded is Map) {
          for (final e in decoded.entries) {
            fields['${e.key}'] = '${e.value ?? ''}';
          }
        }
      } on FormatException {
        // not JSON: no fields
      }
      res.headers.contentType = ContentType.text;
      try {
        final answer = await section.onPost!(fields);
        res.write(answer);
        _done.add('${section.title}: $answer');
      } on PhoneRefused catch (err) {
        res.statusCode = HttpStatus.badRequest;
        res.write(err.message);
        _done.add('${section.title}: ${err.message}');
      }
    } catch (err) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        res.write('The TV could not do that: $err');
      } catch (_) {
        // the answer was under way
      }
    } finally {
      await res.close();
      if (guessed >= 5) {
        unawaited(_server?.close(force: true));
        if (!_closed.isCompleted) _closed.complete();
      }
    }
  }

  /// The page: the sections' forms, each with its own Send button and answer line.
  String pageHtml() {
    final buf = StringBuffer();
    for (final s in sections) {
      final form = s.form.replaceAll('{download}', '/$code/${s.id}/download');
      buf.write(
        '<section id="s-${s.id}" data-section="${s.id}"><h2>${_esc(s.title)}</h2><p>${_esc(s.intro)}</p>$form'
        '${s.onPost == null ? '' : '<button class="send" type="button">${_esc(s.button)}</button>'}'
        '<div class="result" role="status" aria-live="polite"></div></section>',
      );
    }
    return _template
        .replaceAll('{title}', _esc(title))
        .replaceAll('{intro}', _esc(intro))
        .replaceAll('{sections}', buf.toString())
        .replaceAll('{code}', code);
  }
}

String _esc(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

const _template = '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Nevermore IPTV - {title}</title><link rel="icon" href="data:,">
<style>
  body { margin: 0; padding: 16px; font: 16px/1.5 system-ui, sans-serif; background: #101114; color: #f2f4f7; }
  main { max-width: 560px; margin: 0 auto; }
  h1 { font-size: 22px; margin: 8px 0 4px; }
  h2 { font-size: 18px; margin: 28px 0 4px; }
  p { color: #aab0ba; margin: 4px 0 12px; }
  label { display: block; font-weight: 600; margin: 14px 0 6px; }
  label.check { font-weight: 400; }
  input[type=text], input[type=email], input[type=password], input[type=file], textarea { width: 100%;
    box-sizing: border-box; color: #f2f4f7; background: #1c1f25; border: 2px solid #3a4150; border-radius: 8px;
    padding: 10px; font: 16px system-ui, sans-serif; }
  textarea { min-height: 120px; }
  button, a.button { display: block; margin-top: 14px; width: 100%; box-sizing: border-box; padding: 14px; text-align: center;
    font: 600 17px system-ui, sans-serif; color: #101114; background: #a9beda; border: 0; border-radius: 8px;
    text-decoration: none; }
  button:focus-visible, input:focus-visible, textarea:focus-visible, a:focus-visible { outline: 3px solid #ffffff; outline-offset: 2px; }
  .result { margin-top: 12px; font-weight: 600; min-height: 1.5em; }
</style></head>
<body><main>
  <h1>{title}</h1>
  <p>{intro}</p>
  {sections}
</main>
<script>
  document.querySelectorAll('section').forEach((sec) => {
    const btn = sec.querySelector('button.send');
    if (!btn) return;
    btn.addEventListener('click', async () => {
      const out = sec.querySelector('.result');
      out.textContent = 'Sending...';
      const fields = {};
      for (const el of sec.querySelectorAll('[name]')) {
        if (el.type === 'file') fields[el.name] = el.files[0] ? await el.files[0].text() : '';
        else if (el.type === 'checkbox') fields[el.name] = el.checked ? 'yes' : '';
        else fields[el.name] = el.value;
      }
      try {
        const r = await fetch('/{code}/' + sec.dataset.section, { method: 'POST', body: JSON.stringify(fields),
          headers: { 'Content-Type': 'application/json; charset=utf-8' } });
        out.textContent = await r.text();
      } catch (err) {
        out.textContent = 'The TV did not answer. Is the page still open on it?';
      }
    });
  });
</script>
</body></html>''';
