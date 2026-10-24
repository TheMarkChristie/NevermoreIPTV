/// The guide: which XMLTV files to fetch, fetching them, and reading them for the channels shown.
///
/// Sources, first match wins: each login's own guide (`xmltv.php`), the guide address given with an M3U link, the
/// guides a playlist names in its header (when it names five or fewer and none is an all-countries file), then the
/// epgshare01 country files ticked in Settings. A file is fetched when it is missing or over 20 hours old, kept as it
/// came (gzip stays gzip), and refused over 60 MB. Reading it - matching guide channels to this TV's channels and
/// keeping their programmes from three hours ago to 36 hours ahead - runs in another isolate.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'model.dart';
import 'xmltv.dart';

const guideMaxAge = Duration(hours: 20);
const guideMaxBytes = 60 * 1024 * 1024;
const guideMaxHeaderUrls = 5;
const guidePastHours = 3;
const guideAheadHours = 36;

/// epgshare01's free files offered in Settings > Guide: the code kept in settings.json -> (file, name). US2 is the
/// national US channels (NHL, NFL and NBA networks among them) and US_SPORTS1 the leagues' team channels; US1 and CA1
/// do not exist (checked 24 Oct 2026). Never ALL_SOURCES1 (201 MB) or US_LOCALS1 (56 MB).
const epgFiles = {
  'UK': ('UK1', 'UK'),
  'NO': ('NO1', 'Norway'),
  'SE': ('SE1', 'Sweden'),
  'DK': ('DK1', 'Denmark'),
  'IE': ('IE1', 'Ireland'),
  'US': ('US2', 'USA'),
  'US_SPORTS': ('US_SPORTS1', 'US teams'),
  'CA': ('CA2', 'Canada'),
};

/// Code -> name, for the Settings chips.
final epgCountries = {for (final e in epgFiles.entries) e.key: e.value.$2};
const defaultEpgCountries = {'UK', 'NO'};

/// The file a code stands for ("US_SPORTS" -> "US_SPORTS1"); an unknown code keeps the old <code>1 form.
String epgFileFor(String code) => epgFiles[code]?.$1 ?? '${code}1';

String epgshareUrl(String code) => 'https://epgshare01.online/epgshare01/epg_ripper_${epgFileFor(code)}.xml.gz';

/// "https://epgshare01.online/epgshare01/epg_ripper_UK1.xml.gz" -> "epgshare01 UK1".
String guideLabelFor(String url) {
  final uri = Uri.tryParse(url);
  var name = (uri?.pathSegments.where((s) => s.isNotEmpty).lastOrNull) ?? uri?.host ?? url;
  for (final ext in ['.gz', '.xml']) {
    if (name.toLowerCase().endsWith(ext)) name = name.substring(0, name.length - ext.length);
  }
  name = name.replaceFirst('epg_ripper_', 'epgshare01 ');
  return name.isEmpty ? url : name;
}

/// The addresses a playlist header names, when they can be followed: five or fewer, none an all-countries file.
List<String> usableHeaderGuides(List<String> header) {
  final usable = [
    for (final u in header)
      if (!u.toUpperCase().contains('ALL_SOURCES')) u,
  ];
  return usable.length <= guideMaxHeaderUrls ? usable : const [];
}

/// A stable short name for a file: FNV-1a over the address.
String fileKey(String text) {
  var hash = 0xcbf29ce484222325;
  for (final unit in text.codeUnits) {
    hash ^= unit;
    hash *= 0x100000001b3; // wraps at 64 bits
  }
  // two 32-bit halves: a 64-bit int is signed here
  String half(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return half(hash >> 32) + half(hash);
}

class GuideFile {
  GuideFile({required this.label, required this.url, required this.path, this.secret = false});

  final String label;

  /// Never shown when [secret]: a login's guide address carries its password.
  final String url;
  final String path;
  final bool secret;
  DateTime? downloadedAt;
  int size = 0;
  int channels = 0;
  String? error;
  bool busy = false;

  bool get stale => downloadedAt == null || DateTime.now().difference(downloadedAt!) > guideMaxAge;
}

/// Fetches [file] to its path, as it came. Throws with a readable message.
Future<void> downloadGuideFile(GuideFile file, {required String userAgent}) async {
  final client = HttpClient()
    ..autoUncompress = false
    ..userAgent = userAgent
    ..connectionTimeout = const Duration(seconds: 30);
  final part = File('${file.path}.part');
  try {
    final req = await client.getUrl(Uri.parse(file.url));
    // gzip only: a brotli or zstd answer could not be read (a provider chose one on 19 Oct 2026)
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'gzip');
    final resp = await req.close().timeout(const Duration(seconds: 60));
    if (resp.statusCode >= 400) throw HttpException('HTTP ${resp.statusCode}');
    final encoding = (resp.headers.value(HttpHeaders.contentEncodingHeader) ?? '').toLowerCase();
    if (!const {'', 'gzip', 'x-gzip', 'identity'}.contains(encoding)) {
      throw HttpException('answered in $encoding, which cannot be read');
    }
    if (resp.contentLength > guideMaxBytes) {
      throw HttpException('${resp.contentLength ~/ 1000000} MB is over the ${guideMaxBytes ~/ 1048576} MB limit');
    }
    final sink = part.openWrite();
    var size = 0;
    try {
      await for (final chunk in resp.timeout(const Duration(seconds: 60))) {
        size += chunk.length;
        if (size > guideMaxBytes) throw HttpException('over the ${guideMaxBytes ~/ 1048576} MB limit');
        sink.add(chunk);
      }
    } finally {
      await sink.close();
    }
    await part.rename(file.path);
    file
      ..downloadedAt = DateTime.now()
      ..size = size
      ..error = null;
  } finally {
    client.close(force: true);
    if (await part.exists()) await part.delete();
  }
}

/// One source's shown channels and its selection (for manual guide picks).
class GuideChannels {
  const GuideChannels(this.sourceId, this.channels, this.selection);

  final String sourceId;
  final List<Channel> channels;
  final Selection selection;
}

class GuideBuild {
  GuideBuild(this.names, this.errors, this.matches, this.programmes, this.builtAt);

  /// Per file (same order as asked): guide channel id -> display names.
  final List<Map<String, List<String>>> names;
  final List<String?> errors;

  /// Channel uid (`<source id>:<key>`) -> (file index, guide channel id, how).
  final Map<String, (int, String, String)> matches;

  /// Channel uid -> its programmes.
  final Map<String, List<Programme>> programmes;
  final int builtAt;
}

/// Reads the files in another isolate: their channel lists, the matches, and the matched channels' programmes.
/// [files] are (label, path) for the downloaded ones, in priority order.
Future<GuideBuild> buildGuide(List<(String, String)> files, List<GuideChannels> sources, int now) =>
    Isolate.run(() => _buildGuide(files, sources, now));

Future<GuideBuild> _buildGuide(List<(String, String)> files, List<GuideChannels> sources, int now) async {
  final names = <Map<String, List<String>>>[];
  final errors = <String?>[];
  for (final (_, path) in files) {
    try {
      names.add(await readXmltvChannels(path));
      errors.add(null);
    } catch (err) {
      names.add({});
      errors.add('unreadable: ${err is FormatException ? err.message : err}');
    }
  }
  final guideSources = [for (var i = 0; i < files.length; i++) GuideSource(files[i].$1, names[i])];
  final matches = <String, (int, String, String)>{};
  for (final s in sources) {
    matchGuides(s.channels, s.selection, guideSources).forEach((key, m) => matches['${s.sourceId}:$key'] = m);
  }
  final wanted = [for (final _ in files) <String>{}];
  for (final (src, gid, _) in matches.values) {
    wanted[src].add(gid);
  }
  final start = now - guidePastHours * 3600;
  final end = now + guideAheadHours * 3600;
  final bySource = <Map<String, List<Programme>>>[];
  for (var i = 0; i < files.length; i++) {
    try {
      bySource.add(wanted[i].isEmpty ? {} : await readXmltvProgrammes(files[i].$2, wanted[i], start, end));
    } catch (err) {
      errors[i] ??= 'unreadable: $err';
      bySource.add({});
    }
  }
  final programmes = {for (final e in matches.entries) e.key: bySource[e.value.$1][e.value.$2] ?? const <Programme>[]};
  return GuideBuild(names, errors, matches, programmes, now);
}

/// Just the channel lists (for Change guide before the first build of a session).
Future<List<Map<String, List<String>>>> readGuideNames(List<String> paths) => Isolate.run(() => _readGuideNames(paths));

Future<List<Map<String, List<String>>>> _readGuideNames(List<String> paths) async => [
  for (final p in paths) await readXmltvChannels(p).catchError((_) => <String, List<String>>{}),
];
