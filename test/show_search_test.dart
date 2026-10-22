// Searching the guide for a show, and the plain failure messages. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/model.dart';
import 'package:nevermore_iptv/core/reasons.dart';
import 'package:nevermore_iptv/core/show_search.dart';

const now = 1800 * 1000000;

Programme p(int startMin, int stopMin, String title, {String sub = '', String desc = ''}) =>
    Programme(now + startMin * 60, now + stopMin * 60, title, sub, desc);

void main() {
  final programmes = {
    's:a': [p(-60, -5, 'Walker, Texas Ranger'), p(-5, 50, 'Walker, Texas Ranger'), p(600, 660, 'Walker, Texas Ranger')],
    's:b': [p(30, 90, 'Film night', desc: 'Chuck Norris as a Texas Ranger called Walker.')],
    's:c': [p(0, 30, 'Tromsø i dag')],
  };

  test('title matches first, by start; ended programmes left out', () {
    final hits = searchShows(programmes, 'walker texas', now);
    expect(
      [for (final h in hits) (h.uid, h.programme.start, h.inTitle)],
      [
        ('s:a', now - 300, true), // on now
        ('s:a', now + 36000, true),
        ('s:b', now + 1800, false), // only in the description
      ],
    );
  });

  test('case, punctuation and accents do not matter; nothing for nothing', () {
    expect(searchShows(programmes, 'TROMSO', now).single.uid, 's:c');
    expect(searchShows(programmes, 'walker,', now).length, 3);
    expect(searchShows(programmes, '   ', now), isEmpty);
    expect(searchShows(programmes, 'nothing like this', now), isEmpty);
  });

  test('day and time labels', () {
    final today = DateTime.fromMillisecondsSinceEpoch(now * 1000);
    final noon = DateTime(today.year, today.month, today.day, 12).millisecondsSinceEpoch ~/ 1000;
    expect(dayAndTime(noon, noon), 'Today 12:00');
    expect(dayAndTime(noon + 86400, noon), 'Tomorrow 12:00');
    expect(dayAndTime(noon + 3 * 86400, noon), matches(RegExp(r'^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) 12:00$')));
  });

  test('progress', () {
    expect(progressOf(p(0, 60, 'x'), now + 1800), 0.5);
    expect(progressOf(p(0, 60, 'x'), now - 60), 0);
    expect(progressOf(p(0, 60, 'x'), now + 7200), 1);
  });

  test('plain failure messages', () {
    expect(
      friendlyReason('TimeoutException after 0:00:10.000000: Future not completed'),
      'It did not start within 10 seconds.',
    );
    expect(
      friendlyReason('PlatformException(VideoError, Source error: Response code: 403, null)'),
      'The stream answered HTTP 403.',
    );
    expect(
      friendlyReason('UnrecognizedInputFormatException: None of the available extractors'),
      'The stream is in a form this player cannot read.',
    );
    expect(
      friendlyReason('java.net.UnknownHostException: Unable to resolve host "x"'),
      'The stream\'s server could not be found.',
    );
    expect(
      friendlyReason('PlatformException(VideoError, Video player had error xv: MediaCodecAudioRenderer error, index=1'),
      'This TV cannot play this channel\'s sound.',
    );
    expect(friendlyReason('something odd'), 'The player stopped with an error.');
    expect(rawReason('\n  first line  \nsecond'), 'first line');
    expect(rawReason('x' * 200).length, 161);
  });
}
