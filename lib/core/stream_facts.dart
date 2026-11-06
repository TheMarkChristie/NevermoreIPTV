/// What plays, for the channel bar (Mark, 6 Nov 2026, picked "stream facts on the bar"): the picture's height, codec
/// and frame rate, the sound's codec, and the download rate the player measures - "2160p HEVC 25 fps - 14 Mbit/s", so
/// a 4K copy can be judged against an HEVC one. Read from the player plug-in through MainActivity (the plug-in's
/// patch 4, third_party/video_player_android/NEVERMORE.md).
library;

import 'package:flutter/services.dart';

class StreamFacts {
  const StreamFacts({
    this.width = 0,
    this.height = 0,
    this.frameRate = 0,
    this.videoCodec,
    this.videoCodecs,
    this.videoBitrate = 0,
    this.audioCodec,
    this.audioBitrate = 0,
    this.channels = 0,
    this.sampleRate = 0,
    this.bandwidth = 0,
  });

  final int width;
  final int height;
  final double frameRate;

  /// "video/hevc"; null without a picture.
  final String? videoCodec;

  /// "hvc1.1.6.L153.B0", when the stream says.
  final String? videoCodecs;

  /// Bits a second as the stream declares it; 0 when it does not (a TS stream never does).
  final int videoBitrate;
  final String? audioCodec;
  final int audioBitrate;
  final int channels;
  final int sampleRate;

  /// Bits a second as the player measured them arriving, lately.
  final int bandwidth;

  bool get hasVideo => height > 0;
  bool get known => hasVideo || audioCodec != null;

  /// From the plug-in's answer; null for anything but a map.
  static StreamFacts? fromMap(Object? m) {
    if (m is! Map) return null;
    int i(String k) => m[k] is num ? (m[k] as num).toInt() : 0;
    int positive(String k) => i(k) > 0 ? i(k) : 0;
    return StreamFacts(
      width: positive('width'),
      height: positive('height'),
      frameRate: m['frameRate'] is num && (m['frameRate'] as num) > 0 ? (m['frameRate'] as num).toDouble() : 0,
      videoCodec: m['videoCodec'] is String ? m['videoCodec'] as String : null,
      videoCodecs: m['videoCodecs'] is String ? m['videoCodecs'] as String : null,
      videoBitrate: positive('videoBitrate'),
      audioCodec: m['audioCodec'] is String ? m['audioCodec'] as String : null,
      audioBitrate: positive('audioBitrate'),
      channels: positive('channels'),
      sampleRate: positive('sampleRate'),
      bandwidth: positive('bandwidth'),
    );
  }
}

const _videoNames = {
  'video/hevc': 'HEVC',
  'video/x-hevc': 'HEVC',
  'video/avc': 'H.264',
  'video/av01': 'AV1',
  'video/x-vnd.on2.vp9': 'VP9',
  'video/x-vnd.on2.vp8': 'VP8',
  'video/mp4v-es': 'MPEG-4',
  'video/mpeg2': 'MPEG-2',
  'video/mpeg': 'MPEG',
};

const _audioNames = {
  'audio/mp4a-latm': 'AAC',
  'audio/ac3': 'AC-3',
  'audio/eac3': 'E-AC-3',
  'audio/eac3-joc': 'E-AC-3 JOC',
  'audio/mpeg': 'MP3',
  'audio/mpeg-l2': 'MP2',
  'audio/mpeg-l1': 'MP1',
  'audio/opus': 'Opus',
  'audio/true-hd': 'TrueHD',
  'audio/vnd.dts': 'DTS',
  'audio/vnd.dts.hd': 'DTS-HD',
  'audio/raw': 'PCM',
  'audio/flac': 'FLAC',
  'audio/vorbis': 'Vorbis',
};

/// The codec's everyday name: "video/hevc" is "HEVC", "audio/mp4a-latm" is "AAC"; an unknown one is the part after
/// the slash, in capitals; '' for none.
String codecName(String? mime) {
  if (mime == null || mime.isEmpty) return '';
  final m = mime.toLowerCase().trim();
  return _videoNames[m] ?? _audioNames[m] ?? m.split('/').last.toUpperCase();
}

/// "14 Mbit/s" (one decimal under 10), "640 kbit/s"; '' for nothing.
String rate(int bitsPerSecond) {
  if (bitsPerSecond >= 1000000) {
    final m = bitsPerSecond / 1000000;
    return '${m.toStringAsFixed(m < 10 ? 1 : 0)} Mbit/s';
  }
  if (bitsPerSecond >= 1000) return '${(bitsPerSecond / 1000).round()} kbit/s';
  return '';
}

/// "stereo", "5.1", "mono"; '' for unknown.
String channelsName(int channels) => switch (channels) {
  0 => '',
  1 => 'mono',
  2 => 'stereo',
  6 => '5.1',
  8 => '7.1',
  _ => '$channels ch',
};

/// The bar's line: "2160p HEVC 25 fps  -  14 Mbit/s" when the stream declares its rate, else the rate arriving as the
/// player measures it ("4.8 Mbit/s received": a live stream arrives at its own rate, a file as fast as the line goes);
/// "audio AAC stereo  -  128 kbit/s" for sound alone; '' when nothing is known yet.
String describeFacts(StreamFacts f) {
  if (!f.known) return '';
  final parts = <String>[];
  if (f.hasVideo) {
    final codec = codecName(f.videoCodec);
    final fps = f.frameRate > 0 ? ' ${f.frameRate.round()} fps' : '';
    parts.add('${f.height}p${codec.isEmpty ? '' : ' $codec'}$fps');
  } else {
    final sound = [codecName(f.audioCodec), channelsName(f.channels)].where((s) => s.isNotEmpty).join(' ');
    parts.add('audio${sound.isEmpty ? '' : ' $sound'}');
  }
  final declared = f.hasVideo ? f.videoBitrate : f.audioBitrate;
  final r = declared > 0 ? rate(declared) : rate(f.bandwidth);
  if (r.isNotEmpty) parts.add(declared > 0 ? r : '$r received');
  return parts.join('  -  ');
}

const _channel = MethodChannel('nevermore/player');

/// The facts of the player with [playerId], now; null without a platform side or a player.
Future<StreamFacts?> readStreamFacts(int playerId) async {
  try {
    return StreamFacts.fromMap(await _channel.invokeMethod<Object?>('facts', playerId));
  } catch (_) {
    return null;
  }
}
