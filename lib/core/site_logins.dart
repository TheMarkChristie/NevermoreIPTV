/// A site's sign-in, kept on the TV once sent from the phone (Mark, 6 Nov 2026: keep them and refill next time), in
/// the same store as the provider logins. By the site's host, "www." aside.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SiteLogin {
  const SiteLogin(this.user, this.password);

  final String user;
  final String password;
}

/// "https://www.clubtv.example/no/login" -> "clubtv.example"; '' for no host.
String siteHost(String url) => (Uri.tryParse(url)?.host ?? '').toLowerCase().replaceFirst(RegExp(r'^www\.'), '');

class SiteLoginStore {
  SiteLoginStore({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'site_logins';
  final FlutterSecureStorage _storage;
  Map<String, SiteLogin>? _cache;

  Future<Map<String, SiteLogin>> _all() async {
    if (_cache != null) return _cache!;
    final out = <String, SiteLogin>{};
    try {
      final text = await _storage.read(key: _key);
      if (text != null && text.isNotEmpty) {
        final data = jsonDecode(text);
        if (data is Map) {
          for (final e in data.entries) {
            if (e.value is Map) out['${e.key}'] = SiteLogin('${e.value['user'] ?? ''}', '${e.value['password'] ?? ''}');
          }
        }
      }
    } catch (_) {
      // unreadable: none kept
    }
    return _cache = out;
  }

  Future<void> _write() async {
    final all = await _all();
    await _storage.write(
      key: _key,
      value: jsonEncode({
        for (final e in all.entries) e.key: {'user': e.value.user, 'password': e.value.password},
      }),
    );
  }

  /// The login kept for the site of [url], or null.
  Future<SiteLogin?> loginFor(String url) async => (await _all())[siteHost(url)];

  Future<void> remember(String url, SiteLogin login) async {
    final host = siteHost(url);
    if (host.isEmpty) return;
    (await _all())[host] = login;
    await _write();
  }

  Future<void> forget(String url) async {
    if ((await _all()).remove(siteHost(url)) != null) await _write();
  }
}

/// The one store.
final siteLogins = SiteLoginStore();
