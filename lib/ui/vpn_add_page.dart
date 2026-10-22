/// Add a WireGuard file: the address (and a QR code) of the one-time page a phone or computer sends the file to.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/vpn.dart';
import '../core/vpn_upload.dart';
import 'tv.dart';

class VpnAddPage extends StatefulWidget {
  const VpnAddPage({super.key});

  @override
  State<VpnAddPage> createState() => _VpnAddPageState();
}

class _VpnAddPageState extends State<VpnAddPage> {
  VpnUploadServer? _server;
  StreamSubscription<String>? _sub;
  String? _url;
  String? _problem;
  String? _saved;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    // the page is reached over the home network, which a VPN would carry away
    if (vpn.state == VpnState.on || vpn.state == VpnState.connecting) await vpn.turnOff();
    final address = await lanAddress();
    if (address == null) {
      if (mounted) setState(() => _problem = 'This TV is not on a network.');
      return;
    }
    final server = VpnUploadServer(
      accept: (r) async => await vpn.save(r.name, r.text)
          ? null
          : 'That is not a WireGuard file: it needs [Interface] with a PrivateKey and [Peer] with an Endpoint.',
    );
    final port = await server.start();
    _sub = server.received.listen((name) {
      if (mounted) setState(() => _saved = name.isEmpty ? 'the file' : name);
    });
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
    return Scaffold(
      backgroundColor: tvBackground,
      body: Padding(
        padding: overscan,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Add a WireGuard file', style: text.headlineSmall)),
                TvButton(label: 'Done', autofocus: true, onPressed: () => Navigator.of(context).pop()),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Any VPN that gives WireGuard files works (Proton, Mullvad, Surfshark, Windscribe...). Download one for a '
              'server outside the UK, close to you for the best picture. Then, on a phone or computer on the same '
              'network, open this address (or scan the code) and send the file:',
              style: text.bodyMedium?.copyWith(color: tvMuted),
            ),
            const SizedBox(height: 16),
            if (_problem != null) Text(_problem!, style: text.titleMedium?.copyWith(color: tvAlert)),
            if (url == null && _problem == null) const CircularProgressIndicator(),
            if (url != null)
              Expanded(
                child: Row(
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
                        children: [
                          SelectableText(url, style: text.headlineSmall),
                          const SizedBox(height: 12),
                          Text(
                            'The page only works while this screen is open.',
                            style: text.bodySmall?.copyWith(color: tvMuted),
                          ),
                          const SizedBox(height: 16),
                          if (_saved != null) ...[
                            Text('Saved: $_saved', style: text.titleLarge?.copyWith(color: tvAccent)),
                            const SizedBox(height: 4),
                            Text('Press Done, then VPN in the guide to turn it on.', style: text.bodyMedium),
                          ] else
                            Text('Waiting for the file...', style: text.bodyMedium),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
