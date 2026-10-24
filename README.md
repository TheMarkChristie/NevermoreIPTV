# Nevermore IPTV

Live TV for Google TV (Chromecast with Google TV, Google TV Streamer, TVs with Google TV built in), from an Xtream
Codes login or any M3U playlist link. Flutter, built for a TV remote.

The app ships no channels of its own: it plays the free [Free-TV](https://github.com/Free-TV/IPTV) playlist, which
every install starts with, and whatever sources you add.

## What it does

- **Sources:** Xtream Codes logins (server, username, password, checked before saving) and M3U links, any number of
  each. The free Free-TV playlist is added on first start with no login. Logins are kept in Android's encrypted
  storage and never logged.
- **Choosing channels:** tick groups (a channel the provider adds to a ticked group shows by itself), tick or untick
  single channels, rename and move channels and groups, and order the categories across sources.
- **The guide:** each login's own XMLTV guide first, then any guide a playlist names and the free
  [epgshare01](https://epgshare01.online) files you tick (UK, Norway, Sweden, Denmark, Ireland, USA, US team channels,
  Canada). Read as a stream, in the background, matched by guide id and then by name. OK on the video opens the guide over it, with the categories along the top; there is a search
  for shows.
- **Watching:** Up / Down change channel, OK opens the guide, Back twice leaves. One stream at a time (a two-connection
  login is never filled by one TV), streams stop when the app leaves the screen, Xtream channels play as MPEG-TS
  (an HLS session held its connections for over a minute after changing channel).
- **VPN:** a one-press button that sends only this app's traffic through a WireGuard tunnel, from any VPN's WireGuard
  file (added from a phone through a one-time page on the TV, or by the install script). It refuses a UK exit.

## Build

Flutter 3.47 and the Android SDK 36; Java 17.

    flutter test
    flutter build apk --release

Release builds are signed with the key named in `android/key.properties` (not in the repo); without it they fall back
to the debug key. `tools\release.ps1 -Version X -Publish` builds the APK and publishes it as the GitHub release `vX`.

## Install

- **From GitHub:** the APK on the [Releases](https://github.com/TheMarkChristie/NevermoreIPTV/releases) page, copied to
  the TV (the Downloader app, or Send Files to TV) and opened. Once installed, Settings > Update finds a newer release,
  fetches it and opens Android's installer.
- **By script, over the network:** turn on developer options and USB debugging on the TV, then
  `tools\install.ps1 -Tv <TV address>`. It can also hand in a login (`-AskLogin`), a playlist (`-M3uUrl`) or a
  WireGuard file (`-VpnConfig`); `-Pair` uses Android's Wireless debugging instead of the open port 5555.

`tools\make_brand.py` redraws the icon and the TV banner.
