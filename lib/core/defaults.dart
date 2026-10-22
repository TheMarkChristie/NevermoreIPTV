/// What every install starts with. Mark, 19 Oct 2026: "It should always install the default free iptv 3mu link" - the
/// Free-TV playlist, added on the first start (and on the first start after an update, for TVs set up before), with
/// the groups he chose for the Home Assistant player ticked, and the TV's own country's. Removed by hand, it stays
/// removed; Settings offers it again.
library;

const freeTvName = 'Free-TV';
const freeTvUrl = 'https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8';

/// Mark's choice for the IPTV Player, 19 Oct 2026: "UK, Norway, Sweeden, Denmark and Ireland".
const freeTvGroups = ['UK', 'Norway', 'Sweden', 'Denmark', 'Ireland'];

/// The TV's country (from its locale, "nb_NO" -> "NO") as Free-TV names its group.
const _countryGroups = {
  'GB': 'UK',
  'NO': 'Norway',
  'SE': 'Sweden',
  'DK': 'Denmark',
  'IE': 'Ireland',
  'FI': 'Finland',
  'IS': 'Iceland',
  'DE': 'Germany',
  'AT': 'Austria',
  'CH': 'Switzerland',
  'NL': 'Netherlands',
  'BE': 'Belgium',
  'FR': 'France',
  'ES': 'Spain',
  'PT': 'Portugal',
  'IT': 'Italy',
  'PL': 'Poland',
  'US': 'USA',
  'CA': 'Canada',
  'AU': 'Australia',
};

/// The groups ticked when Free-TV is added: Mark's five, and the TV's own country's when Free-TV has one.
List<String> defaultFreeTvGroups(String localeName) {
  final country = RegExp(r'[_-]([A-Za-z]{2})\b').firstMatch(localeName)?.group(1)?.toUpperCase();
  final own = country == null ? null : _countryGroups[country];
  return [...freeTvGroups, if (own != null && !freeTvGroups.contains(own)) own];
}

/// Whether Free-TV is still to be added on this TV: not added before, and not there already (by its address).
bool needsFreeTv({required bool addedBefore, required Iterable<String> sourceUrls}) =>
    !addedBefore && !sourceUrls.any((u) => u.trim() == freeTvUrl);
