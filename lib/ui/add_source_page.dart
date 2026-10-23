/// Add or edit a source: an Xtream Codes login (server, username, password) or an M3U link. Checked before it is saved:
/// a login's account answers ("Active until 19 Nov 2026 - 0 of 2 connections in use"), a playlist is read and counted.
library;

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/sources.dart';
import '../core/xtream.dart';
import 'manage_source_page.dart';
import 'tv.dart';

class AddSourcePage extends StatefulWidget {
  const AddSourcePage({super.key, this.existing, this.firstRun = false, this.onFinished});

  final Source? existing;

  /// The first source on this TV: no Cancel, and the TV opens once groups are chosen.
  final bool firstRun;

  /// Where to go after choosing groups; default back to where this page was opened from.
  final VoidCallback? onFinished;

  @override
  State<AddSourcePage> createState() => _AddSourcePageState();
}

class _AddSourcePageState extends State<AddSourcePage> {
  late SourceKind _kind = widget.existing?.kind ?? SourceKind.xtream;
  late String _name = widget.existing?.name ?? '';
  late String _url = widget.existing?.url ?? '';
  late String _username = widget.existing?.username ?? '';
  late String _password = widget.existing?.password ?? '';
  late String _guide = widget.existing?.guideUrl ?? '';
  late String _output = widget.existing?.output ?? 'ts';
  String? _message;
  bool _busy = false;

  bool get _xtream => _kind == SourceKind.xtream;

  Future<void> _save() async {
    final nav = Navigator.of(context);
    final url = normalAddress(_url);
    if (url.isEmpty || (_xtream && (_username.isEmpty || _password.isEmpty))) {
      setState(
        () =>
            _message = _xtream ? 'Fill in the server address, username and password.' : 'Fill in the playlist address.',
      );
      return;
    }
    final host = Uri.tryParse(url)?.host ?? '';
    final source = Source(
      id: widget.existing?.id ?? Source.newId(),
      kind: _kind,
      name: _name.isNotEmpty ? _name : (_xtream ? (host.isEmpty ? 'My provider' : host) : 'Playlist'),
      url: url,
      username: _xtream ? _username : '',
      password: _xtream ? _password : '',
      guideUrl: _xtream ? '' : normalAddress(_guide),
      output: _output,
    );
    setState(() {
      _busy = true;
      _message = _xtream ? 'Checking the login...' : 'Reading the playlist...';
    });
    try {
      final result = await library.check(source);
      if (!mounted) return;
      setState(() => _message = result.summary);
      await library.saveSource(source, catalog: result.catalog, account: result.account);
      if (!mounted) return;
      final done = widget.onFinished ?? nav.pop;
      if (widget.existing == null) {
        await nav.pushReplacement(
          MaterialPageRoute(
            builder: (_) => ManageSourcePage(sourceId: source.id, firstTime: true, onDone: done),
          ),
        );
      } else {
        nav.pop();
      }
    } on XtreamError catch (err) {
      if (mounted) setState(() => _message = 'Not saved: ${err.message}');
    } catch (err) {
      if (mounted) setState(() => _message = 'Not saved: $err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final editing = widget.existing != null;
    return Scaffold(
      backgroundColor: tvBackground,
      body: Padding(
        padding: overscanOf(context),
        child: ListView(
          children: [
            Text(editing ? 'Edit ${widget.existing!.name}' : 'Add a source', style: text.headlineSmall),
            if (widget.firstRun)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Welcome to Nevermore IPTV. Add your provider login or a playlist link to start.',
                  style: text.bodyMedium?.copyWith(color: tvMuted),
                ),
              ),
            const SizedBox(height: 16),
            if (!editing)
              Row(
                children: [
                  TvButton(
                    label: 'Xtream Codes login',
                    autofocus: true,
                    selected: _xtream,
                    onPressed: () => setState(() => _kind = SourceKind.xtream),
                  ),
                  const SizedBox(width: 10),
                  TvButton(
                    label: 'M3U link',
                    selected: !_xtream,
                    onPressed: () => setState(() => _kind = SourceKind.m3u),
                  ),
                ],
              ),
            const SizedBox(height: 10),
            FieldRow(
              label: 'Name',
              value: _name,
              hint: _xtream ? 'My provider' : 'Playlist',
              autofocus: editing,
              onChanged: (v) => setState(() => _name = v),
            ),
            if (_xtream) ...[
              FieldRow(
                label: 'Server address',
                value: _url,
                hint: 'http://host:8080',
                keyboard: TextInputType.url,
                onChanged: (v) => setState(() => _url = v),
              ),
              FieldRow(label: 'Username', value: _username, onChanged: (v) => setState(() => _username = v)),
              FieldRow(
                label: 'Password',
                value: _password,
                obscure: true,
                onChanged: (v) => setState(() => _password = v),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const SizedBox(width: 190, child: Text('  Streams')),
                  TvButton(
                    label: 'TS (recommended)',
                    selected: _output == 'ts',
                    onPressed: () => setState(() => _output = 'ts'),
                  ),
                  const SizedBox(width: 10),
                  TvButton(
                    label: 'HLS',
                    selected: _output == 'm3u8',
                    onPressed: () => setState(() => _output = 'm3u8'),
                  ),
                ],
              ),
            ] else ...[
              FieldRow(
                label: 'Playlist address',
                value: _url,
                hint: 'https://.../playlist.m3u8',
                keyboard: TextInputType.url,
                onChanged: (v) => setState(() => _url = v),
              ),
              FieldRow(
                label: 'Guide address',
                value: _guide,
                hint: 'Optional: an XMLTV link',
                keyboard: TextInputType.url,
                onChanged: (v) => setState(() => _guide = v),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                TvButton(label: _busy ? 'Checking...' : 'Check and save', onPressed: _busy ? null : _save),
                if (!widget.firstRun) ...[
                  const SizedBox(width: 10),
                  TvButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
                ],
              ],
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_message!, style: text.bodyMedium?.copyWith(color: tvMuted)),
              ),
          ],
        ),
      ),
    );
  }
}
