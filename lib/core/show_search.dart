/// Searching the guide for a show: every word of the query in a programme's title (those first), else in its title,
/// sub-title and description together; programmes that have ended are left out. The guide holds the channels shown on
/// this TV from three hours ago to 36 hours ahead, so that is what a search covers.
library;

import 'model.dart';

class ShowHit {
  const ShowHit(this.uid, this.programme, {required this.inTitle});

  /// The channel (`<source id>:<key>`).
  final String uid;
  final Programme programme;

  /// Every word is in the title (else only in the sub-title or description).
  final bool inTitle;
}

List<String> _words(String text) => [
  for (final w in foldAscii(text).split(RegExp(r'[^a-z0-9]+')))
    if (w.isNotEmpty) w,
];

List<ShowHit> searchShows(Map<String, List<Programme>> programmes, String query, int now, {int limit = 100}) {
  final words = _words(query);
  if (words.isEmpty) return const [];
  final hits = <ShowHit>[];
  programmes.forEach((uid, list) {
    for (final p in list) {
      if (p.stop <= now) continue;
      final title = foldAscii(p.title);
      if (words.every(title.contains)) {
        hits.add(ShowHit(uid, p, inTitle: true));
      } else if (words.every(foldAscii('${p.title} ${p.sub} ${p.desc}').contains)) {
        hits.add(ShowHit(uid, p, inTitle: false));
      }
    }
  });
  hits.sort((a, b) {
    if (a.inTitle != b.inTitle) return a.inTitle ? -1 : 1;
    final s = a.programme.start.compareTo(b.programme.start);
    return s != 0 ? s : a.uid.compareTo(b.uid);
  });
  return hits.length > limit ? hits.sublist(0, limit) : hits;
}

/// "Today 20:00", "Tomorrow 09:00", "Wed 21:00".
String dayAndTime(int epochSeconds, int now) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
  final n = DateTime.fromMillisecondsSinceEpoch(now * 1000);
  // calendar days: local midnights are 23 hours apart on the day the clocks go forward, which .inDays rounds to none
  final days = DateTime.utc(d.year, d.month, d.day).difference(DateTime.utc(n.year, n.month, n.day)).inDays;
  final day = switch (days) {
    0 => 'Today',
    1 => 'Tomorrow',
    _ => const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1],
  };
  return '$day ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// How far through a programme now is, 0 to 1.
double progressOf(Programme p, int now) =>
    p.stop <= p.start ? 0 : ((now - p.start) / (p.stop - p.start)).clamp(0.0, 1.0);
