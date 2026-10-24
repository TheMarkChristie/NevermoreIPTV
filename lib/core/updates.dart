/// A newer Nevermore IPTV on GitHub: found, fetched and handed to Android's installer (Mark, 24 Oct 2026: "yes check for
/// git release"). The release APK is the one build for everyone, the household's house file inside it when the build
/// had one (Mark's decision, 24 Oct 2026); a copy also keeps that file in its data folder (0.7.3).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// The version this build is, shown in Settings and compared with the releases. Checked against pubspec.yaml by a test.
const appVersion = '0.7.5';

/// GitHub's "latest release" answer for the app. A build for a check on the emulator can point it at a local file:
/// --dart-define=NV_UPDATE_API=http://10.0.2.2:8000/latest.json
const releasesApi = String.fromEnvironment(
  'NV_UPDATE_API',
  defaultValue: 'https://api.github.com/repos/TheMarkChristie/NevermoreIPTV/releases/latest',
);

/// One release: its version ("0.7.4" from the tag "v0.7.4"), its APK and its notes.
class Release {
  const Release({
    required this.version,
    required this.apkUrl,
    required this.apkSize,
    required this.notes,
    required this.pageUrl,
  });

  final String version;
  final String apkUrl;

  /// Bytes, 0 when GitHub did not say.
  final int apkSize;
  final String notes;
  final String pageUrl;

  /// As kept in the check stamp between starts.
  Map<String, Object?> toStored() => {
    'version': version,
    'apk': apkUrl,
    'size': apkSize,
    'notes': notes,
    'page': pageUrl,
  };

  static Release? fromStored(Object? j) {
    if (j is! Map || j['version'] is! String || j['apk'] is! String) return null;
    return Release(
      version: j['version'] as String,
      apkUrl: j['apk'] as String,
      apkSize: j['size'] is num ? (j['size'] as num).toInt() : 0,
      notes: '${j['notes'] ?? ''}',
      pageUrl: '${j['page'] ?? ''}',
    );
  }
}

/// The release in GitHub's JSON, or null when there is nothing to install: a draft, a tag without an APK, a tag that is
/// not a version. The APK's address must be https, unless [plainHttp] (a check against a local server).
Release? releaseFromJson(Object? data, {bool plainHttp = false}) {
  if (data is! Map || data['draft'] == true) return null;
  final tag = '${data['tag_name'] ?? ''}'.trim();
  final version = tag.startsWith(RegExp('[vV]')) ? tag.substring(1) : tag;
  if (!RegExp(r'^\d+(\.\d+)*$').hasMatch(version)) return null;
  final assets = data['assets'] is List ? data['assets'] as List : const [];
  final apk = assets.whereType<Map>().where((a) => '${a['name']}'.toLowerCase().endsWith('.apk')).firstOrNull;
  if (apk == null) return null;
  final url = '${apk['browser_download_url'] ?? ''}';
  if (!url.startsWith('https://') && !(plainHttp && url.startsWith('http://'))) return null;
  return Release(
    version: version,
    apkUrl: url,
    apkSize: apk['size'] is num ? (apk['size'] as num).toInt() : 0,
    notes: '${data['body'] ?? ''}',
    pageUrl: '${data['html_url'] ?? ''}',
  );
}

/// Version order by number: "0.7.10" comes after "0.7.9", a missing part is 0, a "+build" part is ignored.
int compareVersions(String a, String b) {
  List<int> parts(String v) => [for (final p in v.split('+').first.split('.')) int.tryParse(p.trim()) ?? 0];
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < pa.length || i < pb.length; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// Asks GitHub for the latest release: null when there is none yet (404) or it carries no APK.
Future<Release?> fetchLatestRelease(
  http.Client client, {
  String api = releasesApi,
  String userAgent = 'NevermoreIPTV',
}) async {
  final resp = await client
      .get(Uri.parse(api), headers: {'Accept': 'application/vnd.github+json', 'User-Agent': userAgent})
      .timeout(const Duration(seconds: 20));
  if (resp.statusCode == 404) return null;
  if (resp.statusCode != 200) throw HttpException('GitHub answered HTTP ${resp.statusCode}');
  return releaseFromJson(jsonDecode(resp.body), plainHttp: api.startsWith('http://'));
}

/// Fetches the release's APK into [into] as `NevermoreIPTV-<version>.apk` (a .part file until it is whole); the size is
/// checked against the asset's when GitHub gave one. Android checks the signature when it installs.
Future<File> downloadRelease(
  http.Client client,
  Release r,
  Directory into, {
  void Function(int got, int total)? progress,
  String userAgent = 'NevermoreIPTV',
}) async {
  await into.create(recursive: true);
  final file = File('${into.path}${Platform.pathSeparator}NevermoreIPTV-${r.version}.apk');
  final part = File('${file.path}.part');
  final req = http.Request('GET', Uri.parse(r.apkUrl))..headers['User-Agent'] = userAgent;
  final resp = await client.send(req).timeout(const Duration(seconds: 30));
  if (resp.statusCode != 200) throw HttpException('The download answered HTTP ${resp.statusCode}');
  final total = resp.contentLength ?? r.apkSize;
  var got = 0;
  final sink = part.openWrite();
  try {
    // written as it arrives (addStream waits for the disk, so a fast connection does not pile the file up in memory);
    // no bytes for a minute is a dead connection, not a slow one
    await sink.addStream(
      resp.stream.timeout(const Duration(seconds: 60)).map((chunk) {
        got += chunk.length;
        progress?.call(got, total);
        return chunk;
      }),
    );
  } finally {
    await sink.close();
  }
  if (r.apkSize > 0 && got != r.apkSize) {
    await part.delete();
    throw const HttpException('The download stopped short');
  }
  if (await file.exists()) await file.delete();
  await part.rename(file.path);
  return file;
}

enum UpdateState { idle, checking, upToDate, available, downloading, downloaded, installing, needsPermission, failed }

/// The update as Settings shows it: checked at most once a day on its own (or when asked), fetched on request, then
/// handed to Android's installer through MainActivity.
class Updater extends ChangeNotifier {
  Updater({required this.current, required this.cacheDir, required this.stampFile, http.Client? client})
    : _client = client ?? http.Client();

  final String current;

  /// The app's cache folder: the APK goes under its updates/ (the FileProvider path the installer may read).
  final Future<Directory> Function() cacheDir;

  /// Where the last check is kept (its time and answer), so a cold start within the day neither asks GitHub again nor
  /// forgets what it said.
  final Future<File> Function() stampFile;
  final http.Client _client;
  static const _channel = MethodChannel('nevermore/update');
  static const _checkEvery = Duration(hours: 20);

  UpdateState state = UpdateState.idle;
  Release? latest;
  DateTime? checkedAt;
  String? error;
  int got = 0;
  int total = 0;
  File? file;

  bool get newer => latest != null && compareVersions(latest!.version, current) > 0;
  bool get busy => state == UpdateState.checking || state == UpdateState.downloading;

  /// The daily check, at start: a recent answer stands (the card and the start notice know it), else GitHub is asked.
  Future<void> checkIfDue() async {
    try {
      final f = await stampFile();
      if (await f.exists()) {
        final stamp = jsonDecode(await f.readAsString());
        final last = stamp is Map ? DateTime.tryParse('${stamp['checked']}') : null;
        if (last != null && DateTime.now().difference(last) < _checkEvery) {
          checkedAt = last;
          latest = Release.fromStored(stamp['release']);
          _set(newer ? UpdateState.available : UpdateState.upToDate);
          return;
        }
      }
    } catch (_) {
      // an unreadable stamp: check now
    }
    await check();
  }

  Future<void> check() async {
    if (busy) return;
    _set(UpdateState.checking);
    try {
      latest = await fetchLatestRelease(_client);
      checkedAt = DateTime.now();
      _set(newer ? UpdateState.available : UpdateState.upToDate);
      try {
        await (await stampFile()).writeAsString(
          jsonEncode({'checked': checkedAt!.toIso8601String(), 'release': latest?.toStored()}),
          flush: true,
        );
      } catch (_) {
        // the stamp is a convenience
      }
    } catch (err) {
      _fail('The check failed: ${err is HttpException ? err.message : err}');
    }
  }

  /// Fetches the APK, then opens the installer.
  Future<void> download() async {
    final r = latest;
    if (r == null || busy) return;
    got = 0;
    total = r.apkSize;
    _set(UpdateState.downloading);
    try {
      final dir = Directory('${(await cacheDir()).path}${Platform.pathSeparator}updates');
      file = await downloadRelease(
        _client,
        r,
        dir,
        progress: (g, t) {
          got = g;
          total = t;
          notifyListeners();
        },
      );
      _set(UpdateState.downloaded);
      await install();
    } catch (err) {
      _fail('The download failed: ${err is HttpException ? err.message : err}');
    }
  }

  /// Hands the fetched APK to Android. "allow": the TV first wants Nevermore allowed to install apps (its settings page
  /// was opened); press Install again afterwards.
  Future<void> install() async {
    final f = file;
    if (f == null) return;
    try {
      final answer = await _channel.invokeMethod<String>('install', f.path);
      _set(answer == 'allow' ? UpdateState.needsPermission : UpdateState.installing);
    } on PlatformException catch (err) {
      _fail('The installer could not be opened: ${err.message ?? err.code}');
    } on MissingPluginException {
      _fail('This build cannot open the installer.');
    }
  }

  void _set(UpdateState s) {
    state = s;
    error = null;
    notifyListeners();
  }

  void _fail(String why) {
    state = UpdateState.failed;
    error = why;
    notifyListeners();
  }
}

/// The one updater, as the library is the one library.
final updater = Updater(
  current: appVersion,
  cacheDir: getTemporaryDirectory,
  stampFile: () async =>
      File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}update-check.txt'),
);
