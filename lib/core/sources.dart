/// The sources set up on this TV: Xtream Codes logins and M3U links. Kept in Android's encrypted storage (Keystore),
/// because a login's password is part of it and an M3U address often carries one too.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

enum SourceKind { xtream, m3u }

class Source {
  Source({
    required this.id,
    required this.kind,
    required this.name,
    required this.url,
    this.username = '',
    this.password = '',
    this.guideUrl = '',
    this.output = 'ts',
  });

  final String id;
  final SourceKind kind;
  final String name;

  /// Xtream: the panel address. M3U: the playlist address.
  final String url;
  final String username;
  final String password;

  /// M3U: an extra guide address (optional).
  final String guideUrl;

  /// Xtream: ts (the default: one connection, freed within seconds) or m3u8.
  final String output;

  bool get isXtream => kind == SourceKind.xtream;

  Source copyWith({String? name, String? url, String? username, String? password, String? guideUrl, String? output}) =>
      Source(
        id: id,
        kind: kind,
        name: name ?? this.name,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
        guideUrl: guideUrl ?? this.guideUrl,
        output: output ?? this.output,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'url': url,
    'username': username,
    'password': password,
    'guide_url': guideUrl,
    'output': output,
  };

  factory Source.fromJson(Map<String, dynamic> j) => Source(
    id: '${j['id']}',
    kind: j['kind'] == 'm3u' ? SourceKind.m3u : SourceKind.xtream,
    name: '${j['name'] ?? ''}',
    url: '${j['url'] ?? ''}',
    username: '${j['username'] ?? ''}',
    password: '${j['password'] ?? ''}',
    guideUrl: '${j['guide_url'] ?? ''}',
    output: j['output'] == 'm3u8' ? 'm3u8' : 'ts',
  );

  static String newId() =>
      '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${Random.secure().nextInt(1 << 20).toRadixString(36)}';
}

/// "provider.example:8080" -> "http://provider.example:8080": an address typed without its scheme.
/// The same login or playlist: one kind, one address (case and a trailing slash aside), one username.
bool sameSource(Source a, Source b) =>
    a.kind == b.kind &&
    normalAddress(a.url).toLowerCase() == normalAddress(b.url).toLowerCase() &&
    a.username.trim().toLowerCase() == b.username.trim().toLowerCase();

String normalAddress(String text) {
  final t = text.trim();
  if (t.isEmpty) return t;
  final withScheme = RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(t) ? t : 'http://$t';
  return withScheme.replaceAll(RegExp(r'/+$'), '');
}

class SourceStore {
  static const _key = 'sources';
  final _storage = const FlutterSecureStorage();

  Future<List<Source>> load() async {
    final text = await _storage.read(key: _key);
    if (text == null || text.isEmpty) return [];
    try {
      return [for (final s in jsonDecode(text) as List) Source.fromJson(Map<String, dynamic>.from(s as Map))];
    } on FormatException {
      return [];
    }
  }

  Future<void> save(List<Source> sources) =>
      _storage.write(key: _key, value: jsonEncode([for (final s in sources) s.toJson()]));
}
