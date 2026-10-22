/// Settings > VPN: the WireGuard file on this TV (from any VPN that gives them), on / off, and adding or removing one.
library;

import 'package:flutter/material.dart';

import '../core/vpn.dart';
import 'tv.dart';
import 'vpn_add_page.dart';

Future<void> openVpnAdd(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VpnAddPage()));

class VpnCard extends StatelessWidget {
  const VpnCard({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: vpn,
      builder: (context, _) {
        final s = vpn.settings;
        final line = switch (vpn.state) {
          VpnState.on => 'On${vpn.country == null ? '' : ': this app appears to be in ${vpn.country}'}',
          VpnState.connecting => 'Connecting...',
          VpnState.failed => vpn.error ?? 'Did not start',
          VpnState.off => 'Off',
        };
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: tvSurface, borderRadius: BorderRadius.circular(10)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('VPN', style: text.titleMedium),
              const SizedBox(height: 4),
              Text(
                s == null
                    ? 'A WireGuard file from any VPN (Proton, Mullvad, Surfshark, Windscribe...), for a server outside '
                          'the UK. Only this app\'s traffic goes through it; the rest of the TV is untouched.'
                    : '${s.name} (${s.endpoint ?? 'no server'})  -  $line',
                style: text.bodySmall?.copyWith(color: vpn.state == VpnState.failed ? tvAlert : tvMuted),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  if (s != null)
                    TvButton(
                      label: vpn.state == VpnState.on || vpn.state == VpnState.connecting ? 'Turn off' : 'Turn on',
                      onPressed: vpn.toggle,
                    ),
                  TvButton(
                    label: s == null ? 'Add a WireGuard file' : 'Replace the file',
                    onPressed: () => openVpnAdd(context),
                  ),
                  if (s != null) TvButton(label: 'Remove the file', onPressed: vpn.remove),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
