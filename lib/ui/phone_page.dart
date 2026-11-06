/// The phone page on the TV's screen: the address and QR code of the page a phone opens (core/phone_page.dart), and
/// what arrives through it. [PhoneSheet] is the part any screen can show (the browser's "From your phone" dialog,
/// Settings' "Your picks" page); [PhonePage] is the Settings page, with this TV's picks to download and a picks file to
/// send (Mark, 6 Nov 2026).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/library.dart';
import '../core/phone_page.dart';
import '../core/picks.dart';
import '../core/vpn_upload.dart' show lanAddress;
import 'tv.dart';

/// The sections of Settings' phone page: this TV's picks to download, a picks file to send.
List<PhoneSection> picksSections() => [
  PhoneSection(
    id: 'picks',
    title: 'This TV\'s picks',
    intro:
        'The sources with their logins, the channels ticked, renamed and ordered, the guide files, Fit or Fill. '
        'Keep the file safe: the logins are in it.',
    form:
        '<a class="button" href="{download}" download="$picksFileName">Download this TV\'s picks</a>'
        '<label for="picks-file">Send a picks file to this TV</label>'
        '<input id="picks-file" type="file" name="file" accept=".json,application/json">'
        '<p>This TV then becomes a copy of the file: its own sources and picks are replaced.</p>',
    button: 'Send to the TV',
    onDownload: () async =>
        (picksFileName, utf8.encode(const JsonEncoder.withIndent(' ').convert(library.exportPicks()))),
    onPost: (fields) async {
      final text = fields['file'] ?? '';
      if (text.trim().isEmpty) throw const PhoneRefused('Pick the picks file first.');
      Object? data;
      try {
        data = jsonDecode(text);
      } on FormatException {
        throw const PhoneRefused('That is not a picks file.');
      }
      final problem = picksProblem(data);
      if (problem != null) throw PhoneRefused(problem);
      return library.restorePicks(Map<String, Object?>.from(data as Map));
    },
  ),
];

/// The address, the QR code and what arrives, for the sections given; the server runs while this is shown.
class PhoneSheet extends StatefulWidget {
  const PhoneSheet({
    super.key,
    required this.title,
    required this.intro,
    required this.sections,
    this.waiting = 'Waiting for the phone...',
  });

  final String title;
  final String intro;
  final List<PhoneSection> sections;
  final String waiting;

  @override
  State<PhoneSheet> createState() => _PhoneSheetState();
}

class _PhoneSheetState extends State<PhoneSheet> {
  PhoneServer? _server;
  StreamSubscription<String>? _sub;
  String? _url;
  String? _problem;
  final List<String> _lines = [];
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final address = await lanAddress();
    if (address == null) {
      if (mounted) setState(() => _problem = 'This TV is not on a network.');
      return;
    }
    final server = PhoneServer(title: widget.title, intro: widget.intro, sections: widget.sections);
    final port = await server.start();
    _sub = server.done.listen((line) {
      if (!mounted) return;
      setState(() {
        _lines.add(line);
        if (_lines.length > 3) _lines.removeAt(0);
      });
    });
    unawaited(
      server.closed.then((_) {
        if (mounted) setState(() => _closed = true);
      }),
    );
    if (!mounted) {
      await server.stop();
      return;
    }
    setState(() {
      _server = server;
      _url = 'http://$address:$port/${server.code}';
    });
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_server?.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final url = _url;
    if (_problem != null) return Text(_problem!, style: text.titleMedium?.copyWith(color: tvAlert));
    if (url == null) return const Center(child: CircularProgressIndicator());
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(10),
          child: QrImageView(data: url, size: 180, backgroundColor: Colors.white),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // plain text: a selectable one took the D-pad focus and kept it
              Text(url, style: text.headlineSmall),
              const SizedBox(height: 8),
              Text(
                'On a phone on the same network: scan the code or open the address. The page only works while this is '
                'open.',
                style: text.bodyMedium?.copyWith(color: tvMuted),
              ),
              const SizedBox(height: 14),
              if (_closed)
                Text(
                  'Closed after five wrong codes: open this again for a new code.',
                  style: text.titleMedium?.copyWith(color: tvAlert),
                )
              else if (_lines.isEmpty)
                Text(widget.waiting, style: text.bodyMedium)
              else
                for (final line in _lines) Text(line, style: text.titleMedium?.copyWith(color: tvAccent)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Settings > Phone: this TV's picks on a phone.
class PhonePage extends StatelessWidget {
  const PhonePage({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return KeepAwake(
      child: Scaffold(
        backgroundColor: tvBackground,
        body: Padding(
          padding: overscanOf(context),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text('Your picks on a phone', style: text.headlineSmall)),
                  TvButton(label: 'Done', autofocus: true, onPressed: () => Navigator.of(context).pop()),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Download this TV\'s picks as a file to keep, or send a picks file to make this TV a copy of another.',
                style: text.bodyMedium?.copyWith(color: tvMuted),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: PhoneSheet(
                  title: 'Your picks',
                  intro: 'This TV\'s picks, down to your phone or up from it.',
                  sections: picksSections(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
