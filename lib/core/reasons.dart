/// The player's error text, said plainly. The card shows this sentence with the player's own first line under it
/// (the raw reason was what found the NRK faults in the Home Assistant player, so it stays on screen).
///
/// What the player sends is `PlatformException(VideoError, Video player had error EXCEPTION [CODE NAME] / CAUSE /
/// CAUSE, null, null)`: the code name and the causes come from the app's patched copy of the plug-in
/// (third_party/video_player_android); the stock plug-in says only "Source error", which told nothing.
library;

String friendlyReason(String error) {
  if (error.contains('TimeoutException')) return 'It did not start within 10 seconds.';
  final code =
      RegExp(r'[Rr]esponse code:?\s*(\d{3})').firstMatch(error)?.group(1) ??
      RegExp(r'HTTP (\d{3})').firstMatch(error)?.group(1);
  if (code != null) return 'The stream answered HTTP $code.';
  // the stream arrived but this TV has no decoder for it (Folketinget TV's AAC-LATM sound on the emulator, 20 Oct 2026)
  if (error.contains('MediaCodecAudioRenderer')) return 'This TV cannot play this channel\'s sound.';
  if (error.contains('MediaCodecVideoRenderer')) return 'This TV cannot play this channel\'s picture.';
  if (error.contains('DECODER_INIT_FAILED') || error.contains('DECODING_FAILED')) {
    return 'This TV cannot play this channel\'s picture or sound.';
  }
  if (error.contains('UnrecognizedInputFormat') ||
      error.contains('ParserException') ||
      error.contains('PARSING_CONTAINER') ||
      error.contains('PARSING_MANIFEST')) {
    return 'The stream is in a form this player cannot read.';
  }
  if (error.contains('UnknownHost') || error.contains('Unable to resolve host')) {
    return 'The stream\'s server could not be found.';
  }
  if (error.contains('NETWORK_CONNECTION_TIMEOUT') || error.contains('SocketTimeout')) {
    return 'The stream did not answer.';
  }
  if (error.contains('ConnectException') ||
      error.contains('Failed to connect') ||
      error.contains('NETWORK_CONNECTION_FAILED') ||
      error.contains('HttpDataSource')) {
    return 'The stream could not be reached.';
  }
  if (error.contains('BEHIND_LIVE_WINDOW')) return 'The stream fell behind and is being started again.';
  if (error.contains('the stream ended')) return 'The stream ended and is being started again.';
  return 'The player stopped with an error.';
}

/// The first line of the player's own text, cut to [max] characters, without the plug-in's wrapping.
String rawReason(String error, {int max = 160}) {
  final bare = error
      .replaceFirst(RegExp(r'^PlatformException\(VideoError, Video player had error '), '')
      .replaceFirst(RegExp(r',\s*null,\s*null\)\s*$'), '')
      .replaceAll('androidx.media3.exoplayer.', '')
      .replaceAll('androidx.media3.datasource.', '');
  final first = bare.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  return first.length > max ? '${first.substring(0, max)}…' : first;
}
