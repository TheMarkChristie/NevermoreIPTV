/// Everything this TV knows about its sources: the sources themselves, each one's channel list (kept on the TV and read
/// again twice a day), what is ticked, renamed and moved, the categories the watch screen shows, and the guide. One
/// instance: [library].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'defaults.dart';
import 'guide.dart';
import 'model.dart';
import 'offthread.dart';
import 'reasons.dart';
import 'show_search.dart';
import 'sources.dart';
import 'xtream.dart';

const userAgent = 'Mozilla/5.0';
const catalogMaxAge = Duration(hours: 12);
const accountMaxAge = Duration(minutes: 15);

final library = Library();

/// A channel ready to show and play: its source, its catalogue entry and the name and category it shows under.
class PlayableChannel {
  PlayableChannel(this.source, this.channel, this.name, this.category);

  final Source source;
  final Channel channel;
  final String name;
  final String category;

  String get uid => '${source.id}:${channel.key}';

  /// Free-TV's Ⓖ: plays only from the channel's own country.
  bool get geoBlocked => channel.name.contains('Ⓖ');
}

/// Groups with the same shown name, from any source, are one category.
class Category {
  Category(this.name, this.channels, this.members);

  final String name;
  final List<PlayableChannel> channels;

  /// The groups in it: (source id, group id).
  final List<(String, String)> members;
}

int nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// Raised whenever matching changes, so a guide cached by the old rules is read again (2: epgshare01's "(NO,NO)" and
/// "[CODE]" names, 0.5.0).
const guideMatcherVersion = 2;

class StreamAddress {
  const StreamAddress(this.url, {required this.hls, required this.headers});

  final String url;
  final bool hls;
  final Map<String, String> headers;
}

class SourceStatus {
  XtreamAccount? account;
  DateTime? accountAt;
  DateTime? readAt;
  String? error;
  bool busy = false;
}

class CheckResult {
  const CheckResult(this.summary, {this.account, this.catalog});

  final String summary;
  final XtreamAccount? account;
  final Catalog? catalog;
}

String formatDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

String formatTime(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String formatCount(int n) => n.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

String accountLine(XtreamAccount a) {
  final until = a.expires == null ? 'no end date' : 'until ${formatDate(a.expires!)}';
  return '${a.status} $until - ${a.active} of ${a.max} connections in use';
}

class Library extends ChangeNotifier {
  final _store = SourceStore();
  List<Source> sources = [];
  final Map<String, Catalog> catalogs = {};
  final Map<String, Selection> selections = {};
  final Map<String, SourceStatus> status = {};

  /// The categories' order across sources: `<source id>:<group id>`. Groups not in it follow in each source's order.
  List<String> groupOrder = [];

  /// The channel last watched on this TV (`<source id>:<channel key>`).
  String? lastChannel;
  final Map<String, XtreamClient> _clients = {};
  final http.Client _http = http.Client();
  Directory? _dir;
  List<Category>? _categories;
  Timer? _tick;

  // the guide
  /// epgshare01 country files ticked in Settings > Guide.
  Set<String> epg = {...defaultEpgCountries};
  List<GuideFile> guideFiles = [];

  /// Channel uid -> (index into [_matchLabels], guide channel id, how).
  Map<String, (int, String, String)> guideMatches = {};
  List<String> _matchLabels = [];

  /// Channel uid -> its programmes, three hours back to 36 hours ahead of [guideBuiltAt].
  Map<String, List<Programme>> programmes = {};
  DateTime? guideBuiltAt;
  bool guideBusy = false;

  /// Guide file label -> its channels (id -> display names), for Change guide.
  Map<String, Map<String, List<String>>> _guideNames = {};
  Timer? _rebuildTimer;
  bool _guideAgain = false;

  Future<Directory> get _folder async => _dir ??= await getApplicationSupportDirectory();

  Future<File> _file(String name) async => File('${(await _folder).path}${Platform.pathSeparator}$name');

  Future<Object?> _readJson(String name) async {
    final f = await _file(name);
    if (!await f.exists()) return null;
    try {
      return await decodeJson(await f.readAsString());
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeJson(String name, Object data) async {
    final f = await _file(name);
    final text = await encodeJson(data);
    final part = File('${f.path}.part');
    await part.writeAsString(text, flush: true);
    await part.rename(f.path);
  }

  SourceStatus statusOf(String id) => status.putIfAbsent(id, SourceStatus.new);

  Selection selectionOf(String id) => selections.putIfAbsent(id, Selection.new);

  Source? sourceById(String id) => sources.where((s) => s.id == id).firstOrNull;

  XtreamClient clientFor(Source s) =>
      _clients.putIfAbsent(s.id, () => XtreamClient(s.url, s.username, s.password, userAgent: userAgent));

  XtreamClient? firstXtreamClient() {
    final s = sources.where((s) => s.isXtream).firstOrNull;
    return s == null ? null : clientFor(s);
  }

  String scrub(Source s, String text) => s.isXtream ? clientFor(s).scrub(text) : text;

  @override
  void notifyListeners() {
    _categories = null;
    super.notifyListeners();
  }

  // ---- loading and saving ----

  Future<void> load() async {
    sources = await _store.load();
    for (final s in sources) {
      final cached = await _readJson('catalog-${s.id}.json');
      if (cached is Map) {
        try {
          catalogs[s.id] = Catalog.fromJson(Map<String, dynamic>.from(cached['catalog'] as Map));
          final readAt = int.tryParse('${cached['read_at']}');
          if (readAt != null) statusOf(s.id).readAt = DateTime.fromMillisecondsSinceEpoch(readAt);
        } catch (_) {
          // an unreadable cache is read again from the source below
        }
      }
      selections[s.id] = Selection.fromJson(await _readJson('selection-${s.id}.json'));
    }
    final layout = await _readJson('layout.json');
    if (layout is Map) groupOrder = [for (final x in (layout['group_order'] as List? ?? const [])) '$x'];
    final device = await _readJson('device.json');
    if (device is Map) {
      lastChannel = device['last'] as String?;
      radio = {for (final uid in (device['radio'] as List? ?? const [])) '$uid'};
    }
    final settings = await _readJson('settings.json');
    if (settings is Map && settings['epg'] is List) epg = {for (final c in settings['epg'] as List) '$c'};
    _freeTvAdded = settings is Map && settings['free_tv_added'] == true;
    await _loadGuideCache();
    // every install starts with the free channels (Mark, 19 Oct 2026); once added, a removal is respected
    if (needsFreeTv(addedBefore: _freeTvAdded, sourceUrls: [for (final s in sources) s.url])) {
      await addFreeTv();
    } else if (!_freeTvAdded) {
      _freeTvAdded = true;
      await _saveSettings();
    }
    notifyListeners();
    unawaited(refreshStale().then((_) => refreshGuide()));
    // while the app is open: lists twice a day, guide files once a day, the guide read again as its window moves on
    _tick ??= Timer.periodic(const Duration(minutes: 30), (_) => refreshStale().then((_) => refreshGuide()));
  }

  /// Reads again every source whose list is missing or over 12 hours old, one source at a time.
  Future<void> refreshStale() async {
    for (final s in List.of(sources)) {
      final readAt = statusOf(s.id).readAt;
      if (catalogs[s.id] == null || readAt == null || DateTime.now().difference(readAt) > catalogMaxAge) {
        await refresh(s);
      }
    }
  }

  /// Checks a source before it is saved: a login's account, or a playlist read and counted.
  Future<CheckResult> check(Source s) async {
    if (s.isXtream) {
      final client = XtreamClient(s.url, s.username, s.password, userAgent: userAgent);
      final account = await client.account();
      return CheckResult(accountLine(account), account: account);
    }
    final catalog = await _readPlaylist(s);
    return CheckResult(
      '${formatCount(catalog.channels.length)} channels in ${catalog.groups.length} groups'
      '${catalog.skipped > 0 ? ', ${formatCount(catalog.skipped)} skipped as unplayable' : ''}',
      catalog: catalog,
    );
  }

  Future<Catalog> _readPlaylist(Source s) async {
    final resp = await _http
        .get(Uri.parse(s.url), headers: {'User-Agent': userAgent})
        .timeout(const Duration(seconds: 60));
    if (resp.statusCode >= 400) throw XtreamError('the playlist address answered HTTP ${resp.statusCode}');
    try {
      return await playlistCatalog(resp.bodyBytes);
    } on FormatException catch (err) {
      throw XtreamError(err.message);
    }
  }

  Future<void> saveSource(Source s, {Catalog? catalog, XtreamAccount? account}) async {
    final i = sources.indexWhere((x) => x.id == s.id);
    if (i >= 0) {
      sources[i] = s;
    } else {
      sources.add(s);
    }
    _clients.remove(s.id);
    await _store.save(sources);
    if (account != null) {
      statusOf(s.id)
        ..account = account
        ..accountAt = DateTime.now();
    }
    if (catalog != null) {
      await _storeCatalog(s, catalog);
    } else {
      notifyListeners();
      unawaited(refresh(s));
    }
  }

  Future<void> removeSource(String id) async {
    sources.removeWhere((s) => s.id == id);
    catalogs.remove(id);
    selections.remove(id);
    status.remove(id);
    _clients.remove(id);
    groupOrder.removeWhere((x) => x.startsWith('$id:'));
    await _store.save(sources);
    for (final name in ['catalog-$id.json', 'selection-$id.json']) {
      final f = await _file(name);
      if (await f.exists()) await f.delete();
    }
    await _writeJson('layout.json', {'group_order': groupOrder});
    notifyListeners();
    scheduleGuideRebuild();
  }

  Future<void> _storeCatalog(Source s, Catalog catalog) async {
    final now = DateTime.now();
    catalogs[s.id] = catalog;
    statusOf(s.id)
      ..readAt = now
      ..error = null;
    notifyListeners();
    await _writeJson('catalog-${s.id}.json', {'read_at': now.millisecondsSinceEpoch, 'catalog': catalog.toJson()});
    scheduleGuideRebuild();
  }

  /// Reads a source's list again (and a login's account).
  Future<void> refresh(Source s) async {
    final st = statusOf(s.id);
    if (st.busy) return;
    st
      ..busy = true
      ..error = null;
    notifyListeners();
    try {
      if (s.isXtream) {
        final client = clientFor(s);
        st
          ..account = await client.account()
          ..accountAt = DateTime.now();
        final groups = await client.liveCategories();
        final streams = await client.liveStreams();
        await _storeCatalog(s, catalogFromXtream(groups, streams));
      } else {
        await _storeCatalog(s, await _readPlaylist(s));
      }
    } catch (err) {
      st.error = scrub(s, err is XtreamError ? err.message : '$err');
    } finally {
      st.busy = false;
      notifyListeners();
    }
  }

  /// A login's account, read again when it is over 15 minutes old (or [force]).
  Future<XtreamAccount?> account(Source s, {bool force = false}) async {
    if (!s.isXtream) return null;
    final st = statusOf(s.id);
    final at = st.accountAt;
    if (!force && st.account != null && at != null && DateTime.now().difference(at) < accountMaxAge) {
      return st.account;
    }
    try {
      st
        ..account = await clientFor(s).account()
        ..accountAt = DateTime.now();
      notifyListeners();
    } on XtreamError catch (err) {
      st.error = err.message;
    }
    return st.account;
  }

  // ---- Manage channels ----

  /// The Manage screens' changes to one source's selection (see [applyChanges]), saved, and the guide read again for
  /// the new channels once the changes settle.
  Future<void> change(String sourceId, List<Map<String, Object?>> changes) async {
    selections[sourceId] = applyChanges(selectionOf(sourceId), changes);
    notifyListeners();
    await _writeJson('selection-$sourceId.json', selections[sourceId]!.toJson());
    scheduleGuideRebuild();
  }

  /// A source's whole selection replaced (a preset), saved, and the guide read again for it.
  Future<void> setSelection(String sourceId, Selection sel) async {
    selections[sourceId] = sel;
    notifyListeners();
    await _writeJson('selection-$sourceId.json', sel.toJson());
    scheduleGuideRebuild();
  }

  Future<void> setGroup(String sourceId, String groupId, bool on) => change(sourceId, [
    {'group': groupId, 'on': on},
  ]);

  /// Renames every group in a category ("" gives the providers' names back). A name another category has merges them.
  Future<void> renameCategory(Category category, String name) async {
    for (final (sourceId, groupId) in category.members) {
      await change(sourceId, [
        {'group': groupId, 'name': name},
      ]);
    }
  }

  /// The categories' order on the TV, as given.
  Future<void> saveCategoryOrder(List<Category> ordered) async {
    groupOrder = [
      for (final c in ordered)
        for (final (sourceId, groupId) in c.members) '$sourceId:$groupId',
    ];
    notifyListeners();
    await _writeJson('layout.json', {'group_order': groupOrder});
  }

  /// A source's channels whose name, renamed name or number has every word of [query].
  List<Channel> searchChannels(String sourceId, String query, {int limit = 200}) {
    final cat = catalogs[sourceId];
    if (cat == null) return const [];
    final sel = selectionOf(sourceId);
    final words = [
      for (final w in query.toLowerCase().split(RegExp(r'\s+')))
        if (w.isNotEmpty) w,
    ];
    if (words.isEmpty) return const [];
    final out = <Channel>[];
    for (final c in cat.channels) {
      final hay = '${displayName(c, sel)} ${c.name} ${c.number ?? ''}'.toLowerCase();
      if (words.every(hay.contains)) {
        out.add(c);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  // ---- what the watch screen shows ----

  List<Category> categories() => _categories ??= _buildCategories();

  List<Category> _buildCategories() {
    final entries = <(String, String, List<PlayableChannel>)>[];
    for (final s in sources) {
      final cat = catalogs[s.id];
      if (cat == null) continue;
      final sel = selectionOf(s.id);
      final byGroup = <String, List<Channel>>{};
      for (final c in shownChannels(cat, sel)) {
        byGroup.putIfAbsent(c.group, () => []).add(c);
      }
      for (final g in orderedGroups(cat, sel)) {
        final list = byGroup[g.id];
        if (list == null) continue;
        final name = withoutMarks(groupName(g, sel));
        entries.add((
          '${s.id}:${g.id}',
          name,
          [for (final c in list) PlayableChannel(s, c, withoutMarks(displayName(c, sel)), name)],
        ));
      }
    }
    final pos = {for (var i = 0; i < groupOrder.length; i++) groupOrder[i]: i};
    final indexed = [for (var i = 0; i < entries.length; i++) (i, entries[i])];
    indexed.sort((a, b) {
      final pa = pos[a.$2.$1];
      final pb = pos[b.$2.$1];
      if (pa != null && pb != null) return pa - pb;
      if (pa != null) return -1;
      if (pb != null) return 1;
      return a.$1 - b.$1;
    });
    final merged = <String, Category>{};
    for (final (_, (uid, name, channels)) in indexed) {
      final c = merged.putIfAbsent(name.toLowerCase(), () => Category(name, [], []));
      c.channels.addAll(channels);
      final bar = uid.indexOf(':');
      c.members.add((uid.substring(0, bar), uid.substring(bar + 1)));
    }
    return merged.values.toList();
  }

  int shownCount(String sourceId) {
    final cat = catalogs[sourceId];
    if (cat == null) return 0;
    final sel = selectionOf(sourceId);
    return cat.channels.where((c) => isShown(c, sel)).length;
  }

  // ---- playing ----

  Future<void> setLastChannel(String uid) async {
    if (lastChannel == uid) return;
    lastChannel = uid;
    await _saveDevice();
  }

  /// Channels that played with sound and no picture (Mark, 24 Oct 2026: "I also want to have radio icon if it's a
  /// radio channel"). Playlists do not say which are radio, and names do not either ("Radio Bremen" is television).
  Set<String> radio = {};

  bool isRadio(PlayableChannel ch) => ch.channel.radio || radio.contains(ch.uid);

  /// What playing a channel showed: sound only, or a picture.
  Future<void> markRadio(String uid, bool on) async {
    if (radio.contains(uid) == on) return;
    if (on) {
      radio.add(uid);
    } else {
      radio.remove(uid);
    }
    notifyListeners();
    await _saveDevice();
  }

  Future<void> _saveDevice() => _writeJson('device.json', {'last': ?lastChannel, 'radio': radio.toList()});

  Future<StreamAddress> streamFor(PlayableChannel ch) async {
    final s = ch.source;
    if (s.isXtream) {
      final client = clientFor(s);
      // the panel names its stream host in the account answer
      if (!client.knowsServer) await account(s, force: true);
      return StreamAddress(
        client.streamUrl(ch.channel.streamId ?? ch.channel.key, s.output),
        hls: s.output == 'm3u8',
        headers: const {'User-Agent': userAgent},
      );
    }
    final url = ch.channel.url ?? '';
    final path = url.toLowerCase().split('?').first;
    return StreamAddress(
      url,
      hls: path.endsWith('.m3u8') || path.endsWith('.m3u'),
      headers: {
        'User-Agent': ch.channel.userAgent ?? userAgent,
        if (ch.channel.referrer != null) 'Referer': ch.channel.referrer!,
      },
    );
  }

  /// Why a channel did not play, as a title and the detail under it.
  Future<(String, String)> explainFailure(PlayableChannel ch, String error) async {
    final reason = scrub(ch.source, error);
    if (ch.source.isXtream) {
      final a = await account(ch.source, force: true);
      if (a != null && a.active >= a.max) {
        return ('Both connections are in use (${a.active} of ${a.max})', 'Stop watching on another TV and try again.');
      }
    }
    if (ch.geoBlocked && reason.contains('403')) {
      return ('Blocked outside its own country', 'This channel only plays in the country it comes from.');
    }
    return ('This channel did not play', '${friendlyReason(reason)}\n${rawReason(reason)}');
  }

  /// Shows on the channels shown here, matching [query] (see [searchShows]), with their channels.
  List<(PlayableChannel, ShowHit)> findShows(String query) {
    final byUid = {
      for (final c in categories())
        for (final ch in c.channels) ch.uid: ch,
    };
    return [
      for (final hit in searchShows(programmes, query, nowSeconds()))
        if (byUid[hit.uid] != null) (byUid[hit.uid]!, hit),
    ];
  }

  // ---- the guide ----

  String _scrubAll(String text) {
    var out = text;
    for (final s in sources.where((s) => s.isXtream)) {
      out = clientFor(s).scrub(out);
    }
    return out;
  }

  Future<List<GuideFile>> _currentGuideFiles() async {
    final folder = (await _folder).path;
    final out = <GuideFile>[];
    void add(String label, String url, {bool secret = false}) {
      if (url.isEmpty || out.any((f) => f.url == url)) return;
      out.add(
        guideFiles.where((f) => f.url == url).firstOrNull ??
            GuideFile(
              label: label,
              url: url,
              path: '$folder${Platform.pathSeparator}guide-${fileKey(url)}.dat',
              secret: secret,
            ),
      );
    }

    for (final s in sources.where((s) => s.isXtream)) {
      add('${s.name} guide', clientFor(s).guideUrl(), secret: true);
    }
    for (final s in sources.where((s) => !s.isXtream)) {
      if (s.guideUrl.isNotEmpty) add(guideLabelFor(s.guideUrl), s.guideUrl);
      for (final u in usableHeaderGuides(catalogs[s.id]?.guideUrls ?? const [])) {
        add(guideLabelFor(u), u);
      }
    }
    for (final code in epgCountries.keys) {
      if (epg.contains(code)) add('epgshare01 ${code}1', epgshareUrl(code));
    }
    for (final f in out) {
      if (f.downloadedAt != null) continue;
      final file = File(f.path);
      if (await file.exists()) {
        final st = await file.stat();
        f
          ..downloadedAt = st.modified
          ..size = st.size;
      }
    }
    return out;
  }

  /// Fetches the guide files ([download] true: all; null: missing or a day old; false: none), then reads them for the
  /// channels shown when anything changed or the last read is over six hours old.
  Future<void> refreshGuide({bool? download}) async {
    if (guideBusy) {
      // asked again while busy (a change settled during a download): read once more afterwards
      _guideAgain = true;
      return;
    }
    guideBusy = true;
    notifyListeners();
    try {
      final before = [for (final f in guideFiles) f.url].join('\n');
      guideFiles = await _currentGuideFiles();
      var changed = download == false || before != [for (final f in guideFiles) f.url].join('\n');
      for (final f in guideFiles) {
        if (download == true || (download == null && f.stale)) {
          f.busy = true;
          notifyListeners();
          try {
            await downloadGuideFile(f, userAgent: userAgent);
            changed = true;
          } catch (err) {
            f.error = _scrubAll(err is HttpException ? err.message : '$err');
          }
          f.busy = false;
          notifyListeners();
        }
      }
      final built = guideBuiltAt;
      if (changed || built == null || DateTime.now().difference(built) > const Duration(hours: 6)) {
        await _rebuildGuide();
      }
    } catch (err) {
      debugPrint('guide: ${_scrubAll('$err')}');
    } finally {
      guideBusy = false;
      notifyListeners();
      if (_guideAgain) {
        _guideAgain = false;
        scheduleGuideRebuild();
      }
    }
  }

  /// After the selection changes: read the guide again for the new channels, once the changes settle.
  void scheduleGuideRebuild() {
    _rebuildTimer?.cancel();
    _rebuildTimer = Timer(const Duration(seconds: 15), () => refreshGuide(download: false));
  }

  Future<void> _rebuildGuide() async {
    final files = [
      for (final f in guideFiles)
        if (f.downloadedAt != null && File(f.path).existsSync()) f,
    ];
    final input = [
      for (final s in sources)
        if (catalogs[s.id] != null)
          GuideChannels(s.id, shownChannels(catalogs[s.id]!, selectionOf(s.id)), selectionOf(s.id)),
    ];
    final build = await buildGuide([for (final f in files) (f.label, f.path)], input, nowSeconds());
    for (var i = 0; i < files.length; i++) {
      files[i]
        ..channels = build.names[i].length
        ..error = build.errors[i] ?? (files[i].error?.startsWith('unreadable') == true ? null : files[i].error);
    }
    _matchLabels = [for (final f in files) f.label];
    _guideNames = {for (var i = 0; i < files.length; i++) files[i].label: build.names[i]};
    guideMatches = build.matches;
    programmes = build.programmes;
    guideBuiltAt = DateTime.fromMillisecondsSinceEpoch(build.builtAt * 1000);
    notifyListeners();
    await _writeJson('guide-cache.json', {
      'built_at': build.builtAt,
      'matcher': guideMatcherVersion,
      'labels': _matchLabels,
      'matches': {
        for (final e in guideMatches.entries) e.key: [e.value.$1, e.value.$2, e.value.$3],
      },
      'programmes': {
        for (final e in programmes.entries)
          e.key: [
            for (final p in e.value) [p.start, p.stop, p.title, p.sub, p.desc, p.category],
          ],
      },
    });
  }

  Future<void> _loadGuideCache() async {
    final cache = await _readJson('guide-cache.json');
    if (cache is! Map) return;
    try {
      _matchLabels = [for (final l in (cache['labels'] as List? ?? const [])) '$l'];
      guideMatches = {
        for (final e in (cache['matches'] as Map? ?? const {}).entries)
          '${e.key}': ((e.value as List)[0] as int, '${(e.value as List)[1]}', '${(e.value as List)[2]}'),
      };
      programmes = {
        for (final e in (cache['programmes'] as Map? ?? const {}).entries)
          '${e.key}': [
            for (final p in e.value as List)
              Programme((p as List)[0] as int, p[1] as int, '${p[2]}', '${p[3]}', '${p[4]}', '${p[5]}'),
          ],
      };
      final built = cache['built_at'];
      // a guide matched by an older matcher is shown, but read again at once (guideBuiltAt left empty)
      if (built is int && cache['matcher'] == guideMatcherVersion) {
        guideBuiltAt = DateTime.fromMillisecondsSinceEpoch(built * 1000);
      }
    } catch (_) {
      programmes = {};
      guideMatches = {};
    }
  }

  Future<void> setEpg(String code, bool on) async {
    if (on) {
      epg.add(code);
    } else {
      epg.remove(code);
    }
    notifyListeners();
    await _saveSettings();
    unawaited(refreshGuide());
  }

  bool _freeTvAdded = false;

  Future<void> _saveSettings() => _writeJson('settings.json', {'epg': epg.toList(), 'free_tv_added': _freeTvAdded});

  bool get hasFreeTv => sources.any((s) => s.url.trim() == freeTvUrl);

  /// The free channels: the Free-TV playlist, its usual groups ticked (and this TV's country's), read in the background.
  Future<void> addFreeTv() async {
    if (hasFreeTv) return;
    final source = Source(id: Source.newId(), kind: SourceKind.m3u, name: freeTvName, url: freeTvUrl);
    // an M3U group's id is its name, so the ticks can be set before the list is read
    selections[source.id] = applyChanges(Selection(), [
      for (final g in defaultFreeTvGroups(Platform.localeName)) {'group': g, 'on': true},
    ]);
    await _writeJson('selection-${source.id}.json', selections[source.id]!.toJson());
    _freeTvAdded = true;
    await _saveSettings();
    await saveSource(source);
  }

  List<Programme> programmesFor(String uid) => programmes[uid] ?? const [];

  (Programme?, Programme?) nowNextFor(String uid) => nowNext(programmes[uid], nowSeconds());

  /// "BBCOneScotland.uk - My provider guide - by guide id", or null when the channel has no guide.
  String? guideMatchText(String uid) {
    final m = guideMatches[uid];
    if (m == null) return null;
    final (src, id, how) = m;
    final label = src < _matchLabels.length ? _matchLabels[src] : '?';
    final by = switch (how) {
      'manual' => 'picked by hand',
      'id' => 'by guide id',
      _ => 'by name',
    };
    return '$id - $label - $by';
  }

  /// Guide channels for Change guide, across every guide file (the provider's first).
  Future<List<({String source, int sourceIndex, String id, String name})>> searchGuide(String query) async {
    if (_guideNames.isEmpty) {
      final files = [
        for (final f in guideFiles)
          if (f.downloadedAt != null && File(f.path).existsSync()) f,
      ];
      final names = await readGuideNames([for (final f in files) f.path]);
      _guideNames = {for (var i = 0; i < files.length; i++) files[i].label: names[i]};
    }
    return searchGuideChannels([for (final e in _guideNames.entries) GuideSource(e.key, e.value)], query);
  }

  // ---- from the install script ----

  /// A source handed over by tools\install.ps1: replaces the source of the same name, else adds one.
  Future<Source?> applySetup(Map<Object?, Object?> setup) async {
    final kind = setup['kind'] == 'm3u' ? SourceKind.m3u : SourceKind.xtream;
    final url = normalAddress('${setup['url'] ?? ''}');
    if (url.isEmpty) return null;
    final name = '${setup['name'] ?? ''}'.trim().isEmpty
        ? (kind == SourceKind.m3u ? 'Playlist' : 'My provider')
        : '${setup['name']}'.trim();
    final existing = sources.where((s) => s.name == name).firstOrNull;
    final source = Source(
      id: existing?.id ?? Source.newId(),
      kind: kind,
      name: name,
      url: url,
      username: '${setup['username'] ?? ''}',
      password: '${setup['password'] ?? ''}',
      guideUrl: '${setup['guide'] ?? ''}',
      output: existing?.output ?? 'ts',
    );
    await saveSource(source);
    return source;
  }
}
