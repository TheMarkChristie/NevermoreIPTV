/// What the player's state means for the channel being watched.
library;

/// True when the stream being watched is over and should be started again: the player reported an error, or it
/// finished.
///
/// The plug-in's completed flag alone is not the end: it is also set whenever the polled position reaches the duration,
/// and a live stream's duration is not real (ExoPlayer has none for it; on 24 Oct 2026 the unknown value reached Dart as
/// 1 ms, every poll looked like the end, and a radio stream was started again twice a second). A finished stream has also
/// stopped, so the flag counts only once the player is neither playing nor buffering.
bool streamEnded({required bool hasError, required bool completed, required bool playing, required bool buffering}) {
  if (hasError) return true;
  return completed && !playing && !buffering;
}

/// True when the picture has stalled: playing, but the position has not moved for 20 s (Mark, 6 Nov 2026: a stalled
/// copy is a failed one, and the next copy of the channel is tried).
bool stalled({required bool playing, required Duration sinceMove}) =>
    playing && sinceMove >= const Duration(seconds: 20);
