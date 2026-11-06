import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/stream_facts.dart';

void main() {
  test('codecs get their everyday names', () {
    expect(codecName('video/hevc'), 'HEVC');
    expect(codecName('video/avc'), 'H.264');
    expect(codecName('audio/mp4a-latm'), 'AAC');
    expect(codecName('audio/eac3'), 'E-AC-3');
    expect(codecName('video/x-new-thing'), 'X-NEW-THING');
    expect(codecName(null), '');
  });

  test('rates read as Mbit/s or kbit/s', () {
    expect(rate(14200000), '14 Mbit/s');
    expect(rate(6450000), '6.5 Mbit/s');
    expect(rate(640000), '640 kbit/s');
    expect(rate(0), '');
  });

  test('the bar line: picture, codec, frame rate and the measured rate', () {
    final f = StreamFacts.fromMap({
      'width': 3840,
      'height': 2160,
      'frameRate': 25.0,
      'videoCodec': 'video/hevc',
      'videoBitrate': -1,
      'audioCodec': 'audio/mp4a-latm',
      'channels': 2,
      'bandwidth': 14200000,
    });
    expect(describeFacts(f!), '2160p HEVC 25 fps  -  14 Mbit/s received');
  });

  test('sound alone, with the declared rate as it is', () {
    final f = StreamFacts.fromMap({
      'audioCodec': 'audio/mp4a-latm',
      'channels': 2,
      'audioBitrate': 128000,
      'bandwidth': 9000000,
    });
    expect(describeFacts(f!), 'audio AAC stereo  -  128 kbit/s');
  });

  test('nothing known yet is an empty line, and a non-map is no facts', () {
    expect(describeFacts(StreamFacts.fromMap({})!), '');
    expect(StreamFacts.fromMap('no'), isNull);
    expect(StreamFacts.fromMap({'height': -1, 'frameRate': -1.0})!.known, isFalse);
  });
}
