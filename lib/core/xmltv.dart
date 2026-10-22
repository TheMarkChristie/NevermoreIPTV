/// XMLTV guide reading, as a stream: the TV never holds a whole guide (the provider's is 146 MB of XML). Port of the
/// IPTV Player's xmltv.py.
///
/// The file is scanned for `<channel>` and `<programme>` elements; only the programmes of wanted channels inside the time
/// window are read. Channels come first in an XMLTV file, so reading the channel list stops at the first programme and
/// costs only the start of the file. Gzip is recognised by its first bytes; a file that is neither gzip nor XML (a
/// brotli or zstd answer, an error page) is refused rather than read as a guide with no channels.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'model.dart';

final _start = RegExp(r'<(channel|programme)[\s>/]');
final _channelAttr = RegExp(r'\schannel="([^"]*)"');
final _idAttr = RegExp(r'\sid="([^"]*)"');
final _display = RegExp(r'<display-name[^>]*>([^<]*)</display-name>');
final _time = RegExp(r'^(\d{14})(?:\s*([+-])(\d{2})(\d{2}))?');
final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|lt|gt|quot|apos|amp);');
final _attrCache = <String, RegExp>{};
final _childCache = <String, RegExp>{};

/// The file as text, a chunk at a time. [rechunk] splits the text into pieces that small (tests: elements split across
/// reads).
Future<Stream<String>> openXmltv(String path, {int? rechunk}) async {
  final probe = await File(path).open();
  final head = await probe.read(64);
  await probe.close();
  final bytes = File(path).openRead();
  Stream<String> text;
  if (head.length >= 2 && head[0] == 0x1f && head[1] == 0x8b) {
    text = bytes.transform(gzip.decoder).transform(const Utf8Decoder(allowMalformed: true));
  } else {
    var i = 0;
    if (head.length >= 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF) i = 3;
    while (i < head.length && (head[i] == 0x20 || head[i] == 0x09 || head[i] == 0x0D || head[i] == 0x0A)) {
      i++;
    }
    if (i >= head.length || head[i] != 0x3C) throw const FormatException('not an XMLTV file');
    text = bytes.transform(const Utf8Decoder(allowMalformed: true));
  }
  final size = rechunk;
  if (size == null) return text;
  return text.expand(
    (s) => [for (var i = 0; i < s.length; i += size) s.substring(i, i + size > s.length ? s.length : i + size)],
  );
}

/// ("channel" | "programme", the element's text) for every top-level element.
Stream<(String, String)> xmltvBlocks(Stream<String> text, {bool stopAtProgramme = false}) async* {
  var buf = '';
  await for (final data in text) {
    buf += data;
    var pos = 0;
    while (true) {
      final m = _start.allMatches(buf, pos).firstOrNull;
      if (m == null) {
        buf = buf.length > 20 ? buf.substring(buf.length - 20) : buf;
        break;
      }
      final tag = m.group(1)!;
      if (stopAtProgramme && tag == 'programme') return;
      final gt = buf.indexOf('>', m.start);
      if (gt < 0) {
        buf = buf.substring(m.start);
        break;
      }
      if (buf[gt - 1] == '/') {
        yield (tag, buf.substring(m.start, gt + 1));
        pos = gt + 1;
        continue;
      }
      final close = buf.indexOf('</$tag>', gt);
      if (close < 0) {
        buf = buf.substring(m.start);
        break;
      }
      final end = close + tag.length + 3;
      yield (tag, buf.substring(m.start, end));
      pos = end;
    }
  }
}

/// '20261019040000 +0100' -> epoch seconds (no offset: UTC).
int? parseXmltvTime(String? text) {
  final m = _time.firstMatch((text ?? '').trim());
  if (m == null) return null;
  final s = m.group(1)!;
  int part(int a, int b) => int.parse(s.substring(a, b));
  final utc = DateTime.utc(part(0, 4), part(4, 6), part(6, 8), part(8, 10), part(10, 12), part(12, 14));
  var t = utc.millisecondsSinceEpoch ~/ 1000;
  if (m.group(2) != null) {
    final offset = int.parse(m.group(3)!) * 3600 + int.parse(m.group(4)!) * 60;
    t = m.group(2) == '+' ? t - offset : t + offset;
  }
  return t;
}

String xmlUnescape(String text) => text.replaceAllMapped(_entity, (m) {
  final e = m.group(1)!;
  switch (e) {
    case 'lt':
      return '<';
    case 'gt':
      return '>';
    case 'quot':
      return '"';
    case 'apos':
      return "'";
    case 'amp':
      return '&';
  }
  final code = e.startsWith('#x') ? int.tryParse(e.substring(2), radix: 16) : int.tryParse(e.substring(1));
  return code == null ? m.group(0)! : String.fromCharCode(code);
});

String? _attr(String head, String name) {
  final re = _attrCache.putIfAbsent(name, () => RegExp('\\s$name="([^"]*)"'));
  final m = re.firstMatch(head);
  return m == null ? null : xmlUnescape(m.group(1)!);
}

String _child(String text, String tag) {
  final re = _childCache.putIfAbsent(tag, () => RegExp('<$tag(?:\\s[^>]*)?>([\\s\\S]*?)</$tag>'));
  final m = re.firstMatch(text);
  if (m == null) return '';
  var value = m.group(1)!;
  if (value.startsWith('<![CDATA[') && value.endsWith(']]>')) {
    return value.substring(9, value.length - 3).trim();
  }
  return xmlUnescape(value).trim();
}

/// Guide channel id -> its display names.
Future<Map<String, List<String>>> readXmltvChannels(String path, {int? rechunk}) async {
  final out = <String, List<String>>{};
  await for (final (tag, text) in xmltvBlocks(await openXmltv(path, rechunk: rechunk), stopAtProgramme: true)) {
    if (tag != 'channel') continue;
    final m = _idAttr.firstMatch(text.substring(0, text.indexOf('>') + 1));
    if (m == null) continue;
    final names = [
      for (final n in _display.allMatches(text))
        if (xmlUnescape(n.group(1)!).trim().isNotEmpty) xmlUnescape(n.group(1)!).trim(),
    ];
    out.putIfAbsent(xmlUnescape(m.group(1)!), () => names);
  }
  return out;
}

/// The wanted channels' programmes that overlap [start, end), sorted, one per start time.
Future<Map<String, List<Programme>>> readXmltvProgrammes(
  String path,
  Set<String> wanted,
  int start,
  int end, {
  int descChars = 600,
  int? rechunk,
}) async {
  if (wanted.isEmpty) return {};
  final out = <String, Map<int, Programme>>{};
  await for (final (tag, text) in xmltvBlocks(await openXmltv(path, rechunk: rechunk))) {
    if (tag != 'programme') continue;
    final head = text.substring(0, text.indexOf('>') + 1);
    final m = _channelAttr.firstMatch(head);
    if (m == null) continue;
    final cid = xmlUnescape(m.group(1)!);
    if (!wanted.contains(cid)) continue;
    final pStart = parseXmltvTime(_attr(head, 'start'));
    if (pStart == null) continue;
    var pStop = parseXmltvTime(_attr(head, 'stop'));
    if (pStop == null || pStop <= pStart) pStop = pStart + 1800;
    if (pStop <= start || pStart >= end) continue;
    var desc = _child(text, 'desc');
    if (desc.length > descChars) {
      desc = desc.substring(0, descChars);
      final space = desc.lastIndexOf(' ');
      if (space >= 0) desc = desc.substring(0, space);
      desc = '$desc…';
    }
    final title = _child(text, 'title');
    out.putIfAbsent(cid, () => {})[pStart] = Programme(
      pStart,
      pStop,
      title.isEmpty ? '?' : title,
      _child(text, 'sub-title'),
      desc,
      _child(text, 'category'),
    );
  }
  return {
    for (final e in out.entries) e.key: [for (final k in (e.value.keys.toList()..sort())) e.value[k]!],
  };
}
