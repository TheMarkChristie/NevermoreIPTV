# video_player_android 2.12.2, patched for Nevermore IPTV

A copy of `video_player_android` 2.12.2 from pub.dev (BSD-3, see LICENSE; the `example/`, `test/` and `pigeons/` folders
left out), used through `dependency_overrides` in the app's `pubspec.yaml`. Three changes, all in
`android/src/main/java/io/flutter/plugins/videoplayer/`, each marked `Nevermore IPTV` in the code:

1. `platformview/PlatformViewExoPlayerEventListener.java`, `sendInitialized()`: a stream with no video track (a radio
   station) has no video format, and the original `Objects.requireNonNull(videoFormat)` threw on Android's main thread,
   which ended the whole process the moment such a stream became ready. The copy reports a zero size instead, as the
   texture listener does, so the app can show its radio sign.
2. `ExoPlayerEventListener.java`, `onPlayerError()`: the error text now carries the error code name and the chain of
   causes (`... [ERROR_CODE_IO_BAD_HTTP_STATUS] / ...InvalidResponseCodeException: Response code: 403`). The original sent
   only `ExoPlaybackException: Source error`, which told the app's failure card nothing.
3. `ExoPlayerEventListener.java`, `durationForDart()`, used by both listeners' `sendInitialized()`: a live stream has no
   duration (`C.TIME_UNSET`, `Long.MIN_VALUE + 1`). Sent as it was, the Dart side's `Duration(milliseconds:)` wrapped it to
   1 ms, every position poll then clamped the position to that and set `isCompleted`, so a live stream looked finished
   twice a second (found with a radio stream on 24 Oct 2026; the provider's TS streams are the same kind). The copy sends
   the largest duration Dart can hold (`Long.MAX_VALUE / 1000` ms) for an unknown one; `isCompleted` is then only set
   by a real end of stream.

When the plug-in is updated: copy the new version over this folder (keeping this file), apply the three changes again,
and check that `flutter pub get` still resolves the override. All three are worth sending upstream.
