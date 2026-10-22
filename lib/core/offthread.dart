/// Work that would stall the screen (megabytes of JSON, a whole playlist), run in another isolate.
///
/// Every closure handed to [Isolate.run] is made here, in a top-level function, so it carries only its own data. A
/// closure made inside a method also carries that method's context, and an object such as a client with requests
/// pending cannot be sent to another isolate ("object is unsendable", found 19 Oct 2026).
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'm3u.dart';
import 'model.dart';

const _small = 200000;

Future<Object?> decodeJson(String text) =>
    text.length < _small ? Future.value(jsonDecode(text)) : Isolate.run(() => jsonDecode(text));

/// [data] must be plain maps, lists and values.
Future<String> encodeJson(Object data) => Isolate.run(() => jsonEncode(data));

/// A playlist's bytes as a catalogue. Throws [FormatException] when they are not an M3U playlist.
Future<Catalog> playlistCatalog(Uint8List bytes) => Isolate.run(() => _playlistCatalog(bytes));

Catalog _playlistCatalog(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  if (!text.trimLeft().replaceFirst('﻿', '').startsWith('#EXTM3U') && !text.contains('#EXTINF')) {
    throw const FormatException('that address is not an M3U playlist');
  }
  return catalogFromM3u(parseM3u(text), headerGuides(text));
}
