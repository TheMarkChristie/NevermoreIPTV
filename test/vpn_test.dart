// The VPN settings check and the country answer. Run: flutter test
import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/vpn.dart';

const proton = '''[Interface]
# Key for Nevermore
# Bouncing = 1
# NetShield = 0
# Moderate NAT = off
# NAT-PMP (Port Forwarding) = off
# VPN Accelerator = on
PrivateKey = aGVsbG8taGVsbG8taGVsbG8taGVsbG8taGVsbG8tMTI=
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
# US-FREE#12
PublicKey = d29ybGQtd29ybGQtd29ybGQtd29ybGQtd29ybGQtMTI=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 203.0.113.7:51820
''';

void main() {
  test('a Proton WireGuard file is accepted, with its server', () {
    final s = VpnSettings.parse('wg-US-FREE-12', proton)!;
    expect(s.name, 'wg-US-FREE-12');
    expect(s.endpoint, '203.0.113.7:51820');
  });

  test('anything else is refused', () {
    expect(VpnSettings.parse('x', 'hello'), isNull);
    expect(VpnSettings.parse('x', proton.replaceAll(RegExp(r'Endpoint.*'), '')), isNull);
    expect(VpnSettings.parse('x', proton.replaceAll(RegExp(r'PrivateKey.*'), '')), isNull);
    expect(VpnSettings.parse('', proton)!.name, 'WireGuard');
  });

  test('the country from Cloudflare\'s trace', () {
    expect(countryFromTrace('fl=123\nh=www.cloudflare.com\nip=203.0.113.7\nloc=US\ntls=TLSv1.3\n'), 'US');
    expect(countryFromTrace('loc=GB\n'), 'GB');
    expect(countryFromTrace('<html>error</html>'), isNull);
  });
}
