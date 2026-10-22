/// The player's error text, said plainly. The card shows this sentence with the player's own first line under it
/// (the raw reason was what found the NRK faults in the Home Assistant player, so it stays on screen).
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
  if (error.contains('UnrecognizedInputFormat') || error.contains('ParserException')) {
    return 'The stream is in a form this player cannot read.';
  }
  if (error.contains('UnknownHost') || error.contains('Unable to resolve host')) {
    return 'The stream\'s server could not be found.';
  }
  if (error.contains('ConnectException') ||
      error.contains('Failed to connect') ||
      error.contains('SocketTimeout') ||
      error.contains('HttpDataSource')) {
    return 'The stream could not be reached.';
  }
  return 'The player stopped with an error.';
}

/// The first line of the player's own text, cut to [max] characters.
String rawReason(String error, {int max = 160}) {
  final first = error.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  return first.length > max ? '${first.substring(0, max)}…' : first;
}
