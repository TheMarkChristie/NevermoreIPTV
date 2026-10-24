// Which of a list of channels get a guide from which epgshare01 files, with the app's own matcher.
//
//   dart run tools/guide_coverage.dart channels.json "epgshare01 US_SPORTS1=path\US_SPORTS1.xml" "epgshare01 US2=..."
//
// channels.json: [{"name": "...", "group": "..."}]; the files are the downloaded XMLTV files (gzip or plain).
// Prints, per file, how many channels it gives a guide and which, then the channels no file covers.
import 'dart:convert';
import 'dart:io';

import 'package:nevermore_iptv/core/guide.dart';
import 'package:nevermore_iptv/core/model.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tools/guide_coverage.dart channels.json "label=path" ...');
    exit(2);
  }
  final rows = (jsonDecode(await File(args[0]).readAsString()) as List).cast<Map>();
  final channels = <Channel>[];
  for (final (i, r) in rows.indexed) {
    final name = '${r['name']}';
    final group = '${r['group']}';
    channels.add(
      Channel(
        'c$i',
        name,
        group,
        i,
        country: countryHint(name: name, group: group),
      ),
    );
  }
  final files = <(String, String)>[];
  for (final a in args.skip(1)) {
    final eq = a.indexOf('=');
    files.add((a.substring(0, eq), a.substring(eq + 1)));
  }
  final build = await buildGuide(files, [
    GuideChannels('p', channels, Selection()),
  ], DateTime.now().millisecondsSinceEpoch ~/ 1000);
  for (final (i, f) in files.indexed) {
    final hits = build.matches.entries.where((e) => e.value.$1 == i).toList();
    final err = build.errors[i];
    stdout.writeln(
      '${f.$1}: ${build.names[i].length} guide channels${err == null ? '' : ' ($err)'}, ${hits.length} of ours matched',
    );
    for (final h in hits) {
      final ch = channels[int.parse(h.key.split(':c').last)];
      stdout.writeln('   ${ch.name}  <-  ${h.value.$2} (${h.value.$3})');
    }
  }
  final unmatched = [
    for (final c in channels)
      if (!build.matches.containsKey('p:${c.key}')) c,
  ];
  stdout.writeln('no guide for ${unmatched.length} of ${channels.length}:');
  for (final c in unmatched) {
    stdout.writeln('   ${c.name}  [${c.group}]');
  }
}
