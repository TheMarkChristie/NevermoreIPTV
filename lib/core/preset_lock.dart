/// A preset's login, locked with its code (Mark, 27 Oct 2026: "when you add in the secret code it doesnt save the
/// username or password - i want to ship it with this"; the house file travels inside the public APK, so the login
/// cannot sit in it plain). The code is the key: scrypt turns it into one, AES-256-GCM holds the login, and the code
/// itself is not written down anywhere - a preset is found by the code unlocking it. `tools/make_house_presets.py`
/// locks; this opens.
///
///     "lock": {"kdf": "scrypt", "n": 16384, "r": 8, "p": 1, "len": 8, "cipher": "aes-256-gcm",
///              "salt": "<base64>", "nonce": "<base64>", "data": "<base64, text and tag>"}
///
/// An eight-digit code is a hundred million guesses, which scrypt makes slow but not impossible for someone who
/// really wants the login; a longer code is the household's choice.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class PresetLock {
  const PresetLock({
    required this.n,
    required this.r,
    required this.p,
    required this.length,
    required this.salt,
    required this.nonce,
    required this.data,
  });

  final int n;
  final int r;
  final int p;

  /// How many digits the code has, so a code being typed is tried once it is complete.
  final int length;
  final Uint8List salt;
  final Uint8List nonce;

  /// The locked text with the cipher's tag after it.
  final Uint8List data;

  /// Null for anything but a lock this code can open (another kdf or cipher, missing parts, odd numbers).
  static PresetLock? fromJson(Object? j) {
    if (j is! Map || j['kdf'] != 'scrypt' || j['cipher'] != 'aes-256-gcm') return null;
    try {
      final n = j['n'] as int;
      final r = j['r'] as int;
      final p = j['p'] as int;
      final length = j['len'] as int;
      if (n < 1024 || n > 1 << 22 || r < 1 || r > 32 || p < 1 || p > 16 || length < 4 || length > 64) return null;
      return PresetLock(
        n: n,
        r: r,
        p: p,
        length: length,
        salt: base64Decode('${j['salt']}'),
        nonce: base64Decode('${j['nonce']}'),
        data: base64Decode('${j['data']}'),
      );
    } catch (_) {
      return null;
    }
  }
}

class PresetLogin {
  const PresetLogin(this.username, this.password);

  final String username;
  final String password;
}

/// Opens the lock with [code] in another isolate (scrypt takes a second or more on a TV); null when the code is not
/// the key - the cipher's tag refuses anything else - or the text inside is not a login.
Future<PresetLogin?> unlockPreset(PresetLock lock, String code) => Isolate.run(() => unlockPresetSync(lock, code));

PresetLogin? unlockPresetSync(PresetLock lock, String code) {
  try {
    final key = _key(lock, code);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, lock.nonce, Uint8List(0)));
    final plain = gcm.process(lock.data);
    final j = jsonDecode(utf8.decode(plain));
    if (j is! Map || j['username'] is! String || j['password'] is! String) return null;
    return PresetLogin(j['username'] as String, j['password'] as String);
  } catch (_) {
    return null;
  }
}

/// Locks a login with a code, as the house file builder does (for the tests; the builder is the Python script).
PresetLock lockPreset(
  String code,
  PresetLogin login, {
  required Uint8List salt,
  required Uint8List nonce,
  int n = 16384,
}) {
  final text = utf8.encode(jsonEncode({'username': login.username, 'password': login.password}));
  final draft = PresetLock(n: n, r: 8, p: 1, length: code.length, salt: salt, nonce: nonce, data: Uint8List(0));
  final gcm = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(_key(draft, code)), 128, nonce, Uint8List(0)));
  return PresetLock(
    n: n,
    r: 8,
    p: 1,
    length: code.length,
    salt: salt,
    nonce: nonce,
    data: gcm.process(Uint8List.fromList(text)),
  );
}

Uint8List _key(PresetLock lock, String code) {
  final kdf = Scrypt()..init(ScryptParameters(lock.n, lock.r, lock.p, 32, lock.salt));
  return kdf.process(Uint8List.fromList(utf8.encode(code)));
}
