/// The Xtream Codes player API, asked gently: one request at a time, a second apart.
///
///     player_api.php?username=&password=                          the account (user_info) and the server (server_info)
///     player_api.php?...&action=get_live_categories               live groups
///     player_api.php?...&action=get_live_streams[&category_id=]   live channels
///     xmltv.php?username=&password=                               the provider's guide
///     <protocol>://<server>:<port>/live/<user>/<password>/<stream id>.<m3u8|ts>     a channel
///
/// The password is in every address, so addresses are only built here and none is ever logged: run any text that might
/// hold one through [XtreamClient.scrub] first.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'offthread.dart';

class XtreamError implements Exception {
  XtreamError(this.message);
  final String message;

  @override
  String toString() => message;
}

class XtreamAccount {
  const XtreamAccount({required this.active, required this.max, required this.status, this.expires});

  final int active;
  final int max;
  final String status;
  final DateTime? expires;
}

/// Whatever a text carries that looks like a login, masked by shape: username= and password= query values, and the two
/// segments after /live/ in a stream address. Used before any error text reaches a screen or a log.
String redactSecrets(String text) => text
    .replaceAllMapped(
      RegExp(r'([?&](?:username|password|user|pass)=)[^&\s"]+', caseSensitive: false),
      (m) => '${m[1]}***',
    )
    .replaceAllMapped(RegExp(r'(/live/)[^/\s]+/[^/\s]+(/)'), (m) => '${m[1]}***/***${m[2]}');

class XtreamClient {
  XtreamClient(String url, this._username, this._password, {this.userAgent = 'Mozilla/5.0'})
    : base = url.trim().replaceAll(RegExp(r'/+$'), '');

  final String base;
  final String _username;
  final String _password;
  final String userAgent;
  final http.Client _http = http.Client();
  Map<String, dynamic> _server = const {};
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _queue = Future.value();

  /// The text with the login taken out, in every form it travels in: as typed, as a URL component and as a query value
  /// (a space becomes "+", "!*'()" are percent-encoded there, which is what package:http's errors carry).
  String scrub(String text) {
    var out = redactSecrets(text);
    for (final secret in {
      _password,
      Uri.encodeComponent(_password),
      Uri.encodeQueryComponent(_password),
      _username,
      Uri.encodeComponent(_username),
      Uri.encodeQueryComponent(_username),
    }) {
      if (secret.length >= 2) out = out.replaceAll(secret, '***');
    }
    return out;
  }

  Future<dynamic> _get(Map<String, String> params) {
    final next = _queue.then((_) async {
      final wait = _last.add(const Duration(seconds: 1)).difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      final uri = Uri.parse('$base/player_api.php')
          .replace(queryParameters: {'username': _username, 'password': _password, ...params});
      try {
        final resp = await _http.get(uri, headers: {'User-Agent': userAgent}).timeout(const Duration(seconds: 30));
        if (resp.statusCode == 401 || resp.statusCode == 403) {
          throw XtreamError('the provider refused the login (HTTP ${resp.statusCode})');
        }
        if (resp.statusCode >= 400) throw XtreamError('the provider answered HTTP ${resp.statusCode}');
        // a full channel list is megabytes of JSON: decoded off the screen's thread
        return await decodeJson(utf8.decode(resp.bodyBytes, allowMalformed: true));
      } on XtreamError {
        rethrow;
      } catch (err) {
        throw XtreamError(scrub('${err.runtimeType}: $err'));
      } finally {
        _last = DateTime.now();
      }
    });
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// The account. Checks the `auth` field, not just the HTTP status: some panels answer a wrong login with 200 and
  /// `auth: 0`. Keeps server_info for building play addresses.
  Future<XtreamAccount> account() async {
    final data = await _get(const {});
    if (data is! Map || data['user_info'] is! Map) {
      throw XtreamError('not an Xtream Codes panel: player_api.php gave no account');
    }
    final user = data['user_info'] as Map;
    if ('${user['auth']}' != '1') throw XtreamError('the provider refused the login');
    final status = '${user['status'] ?? ''}';
    if (status.isNotEmpty && status.toLowerCase() != 'active') throw XtreamError('the account is $status');
    _server = Map<String, dynamic>.from((data['server_info'] as Map?) ?? const {});
    final expires = int.tryParse('${user['exp_date']}');
    return XtreamAccount(
      active: int.tryParse('${user['active_cons']}') ?? 0,
      max: int.tryParse('${user['max_connections']}') ?? 1,
      status: status.isEmpty ? 'Active' : status,
      expires: expires == null ? null : DateTime.fromMillisecondsSinceEpoch(expires * 1000),
    );
  }

  Future<List<Map<String, dynamic>>> liveCategories() async =>
      _list(await _get(const {'action': 'get_live_categories'}));

  Future<List<Map<String, dynamic>>> liveStreams({String? categoryId}) async =>
      _list(await _get({'action': 'get_live_streams', 'category_id': ?categoryId}));

  static List<Map<String, dynamic>> _list(dynamic data) => data is List
      ? [
          for (final e in data)
            if (e is Map) Map<String, dynamic>.from(e),
        ]
      : const [];

  /// The provider's whole guide (it carries the password: never shown, never logged).
  String guideUrl() =>
      Uri.parse('$base/xmltv.php').replace(queryParameters: {'username': _username, 'password': _password}).toString();

  /// Whether [account] has run, so play addresses use the host the panel names.
  bool get knowsServer => _server.isNotEmpty;

  /// Where the panel says its streams are (server_info), else the address the API answered on.
  String streamBase() {
    final host = '${_server['url'] ?? ''}'.trim();
    if (host.isEmpty) return base;
    final proto = '${_server['server_protocol'] ?? 'http'}'.toLowerCase();
    final port = '${(proto == 'https' ? _server['https_port'] : _server['port']) ?? ''}'.trim();
    final standard = proto == 'https' ? '443' : '80';
    return '$proto://$host${port.isNotEmpty && port != standard ? ':$port' : ''}';
  }

  String streamUrl(String streamId, String output) {
    final ext = output == 'ts' ? 'ts' : 'm3u8';
    return '${streamBase()}/live/${Uri.encodeComponent(_username)}/${Uri.encodeComponent(_password)}/'
        '${Uri.encodeComponent(streamId)}.$ext';
  }
}
