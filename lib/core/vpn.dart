/// The VPN button: this app's own traffic through a WireGuard tunnel. Mark, 19 Oct 2026: "Let's go with proton free,
/// it just can't be UK", then "Go with anything that lets me install a wiregaurd file".
///
/// The settings are a WireGuard file from any VPN that gives them (Proton, Mullvad, Surfshark, Windscribe, a server of
/// one's own), for a server outside the UK. It comes in through Add a WireGuard file (a one-time page a phone or
/// computer sends it to, vpn_upload.dart) or tools\install.ps1 -VpnConfig, and is kept in Android's encrypted storage.
/// Only this app's
/// traffic goes through the tunnel (WireGuard's IncludedApplications), so the rest of the TV is untouched. Once it is
/// up, the app asks Cloudflare where it now appears to be; a UK answer, or none, turns it off again.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:wireguard_flutter_plus/wireguard_flutter_platform_interface.dart';
import 'package:wireguard_flutter_plus/wireguard_flutter_plus.dart';

const appPackage = 'com.themarkchristie.nevermoreiptv';

/// A WireGuard file, checked enough to know it is one.
class VpnSettings {
  const VpnSettings(this.name, this.text);

  /// "wg-US-FREE-12" (the file's name, as handed in).
  final String name;
  final String text;

  String? get endpoint => RegExp(r'^\s*Endpoint\s*=\s*(\S+)', multiLine: true).firstMatch(text)?.group(1);

  /// Null when [text] is not a WireGuard file with a private key and a server.
  static VpnSettings? parse(String name, String text) {
    final ok =
        RegExp(r'^\s*\[Interface\]', multiLine: true).hasMatch(text) &&
        RegExp(r'^\s*PrivateKey\s*=', multiLine: true).hasMatch(text) &&
        RegExp(r'^\s*\[Peer\]', multiLine: true).hasMatch(text) &&
        RegExp(r'^\s*Endpoint\s*=\s*\S+', multiLine: true).hasMatch(text);
    return ok ? VpnSettings(name.trim().isEmpty ? 'WireGuard' : name.trim(), text) : null;
  }
}

/// "loc=US" in Cloudflare's trace answer -> "US".
String? countryFromTrace(String body) => RegExp(r'^loc=([A-Z]{2})\s*$', multiLine: true).firstMatch(body)?.group(1);

enum VpnState { off, connecting, on, failed }

final vpn = Vpn();

class Vpn extends ChangeNotifier {
  final _storage = const FlutterSecureStorage();
  VpnSettings? settings;
  VpnState state = VpnState.off;

  /// Where this app appears to be through the tunnel ("US").
  String? country;
  String? error;
  bool _ready = false;
  StreamSubscription<VpnStage>? _stages;
  VpnStage _stage = VpnStage.disconnected;

  WireGuardFlutterInterface get _wg => WireGuardFlutter.instance;

  /// Android's "allow this VPN" question, asked by MainActivity. The plug-in asks it too but never hears the answer,
  /// so the first press after an install waited forever (22 Oct 2026); asked here first, the plug-in finds it given.
  static const _android = MethodChannel('nevermore/vpn');

  Future<void> load() async {
    final text = await _storage.read(key: 'vpn.conf');
    final name = await _storage.read(key: 'vpn.name');
    if (text != null) settings = VpnSettings.parse(name ?? '', text);
    // Nothing more until the button is pressed: setting the VPN up is what makes Android ask to allow it, and that must
    // not appear at every start. The app takes the tunnel down when it is left, so none is waiting from before.
    notifyListeners();
  }

  Future<void> _init() async {
    if (_ready) return;
    await _wg.initialize(interfaceName: 'nevermore', vpnName: 'Nevermore IPTV');
    _stages = _wg.vpnStageSnapshot.listen((s) => _stage = s);
    _ready = true;
  }

  /// Saves settings handed in by the install script. False when they are not a WireGuard file.
  Future<bool> save(String name, String text) async {
    final s = VpnSettings.parse(name, text);
    if (s == null) return false;
    await _storage.write(key: 'vpn.conf', value: s.text);
    await _storage.write(key: 'vpn.name', value: s.name);
    if (state == VpnState.on) await turnOff();
    settings = s;
    error = null;
    notifyListeners();
    return true;
  }

  Future<void> remove() async {
    await turnOff();
    await _storage.delete(key: 'vpn.conf');
    await _storage.delete(key: 'vpn.name');
    settings = null;
    notifyListeners();
  }

  Future<void> toggle() => state == VpnState.on || state == VpnState.connecting ? turnOff() : turnOn();

  Future<void> turnOn() async {
    final s = settings;
    if (s == null) {
      state = VpnState.failed;
      error = 'No VPN settings on this TV yet.';
      notifyListeners();
      return;
    }
    state = VpnState.connecting;
    error = null;
    country = null;
    notifyListeners();
    try {
      // Android asks once to allow the VPN; only this app's traffic goes through it
      if (await _android.invokeMethod<bool>('allow') != true) throw StateError('the VPN was not allowed on this TV');
      await _init();
      await _wg
          .startVpn(
            serverAddress: s.endpoint ?? '',
            wgQuickConfig: s.text,
            providerBundleIdentifier: appPackage,
            includedApps: const [appPackage],
          )
          .timeout(const Duration(seconds: 30));
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (_stage != VpnStage.connected && await _wg.stage() != VpnStage.connected) {
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('the tunnel did not come up');
        if (_stage == VpnStage.denied) throw StateError('the VPN was not allowed on this TV');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      state = VpnState.on;
      notifyListeners();
      await _checkCountry();
    } catch (err) {
      await _stop();
      state = VpnState.failed;
      error = err is TimeoutException
          ? 'The VPN did not start. Check the settings, or download them for another server.'
          : err is StateError
          ? err.message
          : 'The VPN did not start: $err';
      notifyListeners();
    }
  }

  /// Where the app now appears to be. The UK, or no answer through the tunnel, turns the VPN off again.
  Future<void> _checkCountry() async {
    String? where;
    for (var attempt = 0; attempt < 3 && where == null; attempt++) {
      try {
        final resp = await http
            .get(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
            .timeout(const Duration(seconds: 8));
        where = countryFromTrace(resp.body);
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    if (where == null) {
      await _stop();
      state = VpnState.failed;
      error =
          'Nothing answers through the VPN. Its server may be down or full: download settings for another '
          'free server.';
    } else if (where == 'GB') {
      await _stop();
      state = VpnState.failed;
      error = 'That server is in the UK. Download settings for a free server in another country.';
    } else {
      country = where;
    }
    notifyListeners();
  }

  Future<void> turnOff() async {
    await _stop();
    state = VpnState.off;
    country = null;
    notifyListeners();
  }

  Future<void> _stop() async {
    try {
      if (_ready) await _wg.stopVpn();
    } catch (_) {
      // already down
    }
  }

  /// "VPN off", "VPN: US", "VPN...".
  String get label => switch (state) {
    VpnState.on => country == null ? 'VPN: on' : 'VPN: $country',
    VpnState.connecting => 'VPN...',
    _ => 'VPN off',
  };

  @override
  void dispose() {
    _stages?.cancel();
    super.dispose();
  }
}
