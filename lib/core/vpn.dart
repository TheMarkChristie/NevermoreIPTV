/// The VPN button: this app's own traffic through a WireGuard tunnel. Mark, 19 Oct 2026: "Let's go with proton free,
/// it just can't be UK", then "Go with anything that lets me install a wiregaurd file".
///
/// The settings are a WireGuard file from any VPN that gives them (Proton, Mullvad, Surfshark, Windscribe, a server of
/// one's own), for a server outside the UK. It comes in through Add a WireGuard file (a one-time page a phone or
/// computer sends it to, vpn_upload.dart) or tools\install.ps1 -VpnConfig, and is kept in Android's encrypted storage.
/// Only this app's traffic goes through the tunnel (WireGuard's IncludedApplications), so the rest of the TV is
/// untouched. Once it is up, the app asks where it now appears to be; a UK answer, or none, turns it off again. A
/// tunnel that goes away while on (Android revoked it, another VPN app took over) turns the state to failed, so the
/// watch screen stops rather than play on over the real address.
library;

import 'dart:async';
import 'dart:convert';

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

/// {"country":"NL"} from api.country.is -> "NL" (the second place asked when Cloudflare does not answer).
String? countryFromJson(String body) {
  try {
    final data = jsonDecode(body);
    final c = data is Map ? '${data['country'] ?? ''}'.trim().toUpperCase() : '';
    return RegExp(r'^[A-Z]{2}$').hasMatch(c) ? c : null;
  } on FormatException {
    return null;
  }
}

/// Why a start failed, in plain words (the plug-in's codes are its own).
String vpnStartFailure(Object err) {
  if (err is TimeoutException) return 'The VPN did not start. Check the settings, or download them for another server.';
  if (err is StateError) return err.message;
  if (err is PlatformException) {
    return switch (err.code) {
      'DNS_RESOLUTION_FAILURE' => 'The VPN server could not be found. Is the TV online?',
      'VPN_NOT_AUTHORIZED' || 'PERMISSION_DENIED' => 'The VPN was not allowed on this TV.',
      'UNABLE_TO_START_VPN' ||
      'TUN_CREATION_ERROR' ||
      'GO_ACTIVATION_ERROR_CODE' => 'The VPN could not be started on this TV. Another VPN app may be running.',
      _ => 'The VPN did not start (${err.code}).',
    };
  }
  return 'The VPN did not start: $err';
}

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
  Future<void>? _initing;
  StreamSubscription<VpnStage>? _stages;
  VpnStage _stage = VpnStage.disconnected;
  bool _stopping = false;

  /// Counts the presses: a start overtaken by a stop (or another start) gives up where it is instead of finishing
  /// later and turning the VPN on behind the viewer's back (review, 24 Oct 2026).
  int _gen = 0;

  WireGuardFlutterInterface get _wg => WireGuardFlutter.instance;

  /// MainActivity: Android's "allow this VPN" question (the plug-in asks it too but never hears the answer, so the first
  /// press after an install waited forever, 22 Oct 2026), and "forget", which clears the plug-in's own plain-text copy
  /// of the file.
  static const _android = MethodChannel('nevermore/vpn');

  Future<void> load() async {
    final text = await _storage.read(key: 'vpn.conf');
    final name = await _storage.read(key: 'vpn.name');
    if (text != null) settings = VpnSettings.parse(name ?? '', text);
    // Nothing more until the button is pressed: setting the VPN up is what makes Android ask to allow it, and that must
    // not appear at every start. Nothing runs from before (the process ends on leaving), so the plug-in's copy can go.
    await _forget();
    notifyListeners();
  }

  /// The plug-in keeps the whole file, private key included, in plain preferences while a tunnel runs and only removes
  /// it on its own disconnect; cleared here whenever the tunnel is down.
  Future<void> _forget() async {
    try {
      await _android.invokeMethod<void>('forget');
    } catch (_) {
      // an older MainActivity without it
    }
  }

  Future<void> _init() async {
    if (_ready) return;
    final running = _initing;
    if (running != null) {
      await running;
      return;
    }
    final mine = _initing = _doInit();
    try {
      await mine;
    } finally {
      _initing = null;
    }
  }

  Future<void> _doInit() async {
    await _wg.initialize(interfaceName: 'nevermore', vpnName: 'Nevermore IPTV');
    _stages = _wg.vpnStageSnapshot.listen(_onStage);
    _ready = true;
  }

  /// The tunnel's own word on itself. Gone while the app thought it was on: the state turns to failed, and the watch
  /// screen stops the stream rather than let it come back over the real address unnoticed.
  void _onStage(VpnStage s) {
    _stage = s;
    if (_stopping || state != VpnState.on) return;
    if (s == VpnStage.disconnected || s == VpnStage.denied) {
      state = VpnState.failed;
      country = null;
      error = 'The VPN dropped. Press OK on VPN to start it again.';
      notifyListeners();
      unawaited(_forget());
    }
  }

  /// Saves settings handed in by the install script. False when they are not a WireGuard file.
  Future<bool> save(String name, String text) async {
    final s = VpnSettings.parse(name, text);
    if (s == null) return false;
    await _storage.write(key: 'vpn.conf', value: s.text);
    await _storage.write(key: 'vpn.name', value: s.name);
    if (state == VpnState.on || state == VpnState.connecting) await turnOff();
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
    final gen = ++_gen;
    state = VpnState.connecting;
    error = null;
    country = null;
    notifyListeners();
    try {
      // Android asks once to allow the VPN; only this app's traffic goes through it
      if (await _android.invokeMethod<bool>('allow') != true) throw StateError('the VPN was not allowed on this TV');
      if (gen != _gen) return;
      await _init();
      if (gen != _gen) return;
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
        if (gen != _gen) {
          await _stop();
          return;
        }
        if (DateTime.now().isAfter(deadline)) throw TimeoutException('the tunnel did not come up');
        if (_stage == VpnStage.denied) throw StateError('the VPN was not allowed on this TV');
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (gen != _gen) {
        await _stop();
        return;
      }
      state = VpnState.on;
      notifyListeners();
      await _checkCountry(gen);
    } catch (err) {
      if (gen != _gen) return;
      await _stop();
      state = VpnState.failed;
      error = vpnStartFailure(err);
      notifyListeners();
    }
  }

  /// Where the app now appears to be. The UK, or no answer through the tunnel, turns the VPN off again.
  Future<void> _checkCountry(int gen) async {
    String? where;
    for (var attempt = 0; attempt < 3 && where == null; attempt++) {
      where =
          await _askCountry('https://www.cloudflare.com/cdn-cgi/trace', countryFromTrace) ??
          await _askCountry('https://api.country.is', countryFromJson);
      if (gen != _gen) return;
      if (where == null) await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (gen != _gen) return;
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

  Future<String?> _askCountry(String url, String? Function(String body) read) async {
    try {
      final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 8));
      return resp.statusCode == 200 ? read(resp.body) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> turnOff() async {
    _gen++;
    await _stop();
    state = VpnState.off;
    country = null;
    error = null;
    notifyListeners();
    await _forget();
  }

  Future<void> _stop() async {
    _stopping = true;
    try {
      // a start still setting the plug-in up: let it finish, then stop what it started
      final starting = _initing;
      if (starting != null) await starting.catchError((_) {});
      if (_ready) await _wg.stopVpn().timeout(const Duration(seconds: 5));
    } catch (_) {
      // already down, or not answering: the end of the process takes it down
    } finally {
      _stopping = false;
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
