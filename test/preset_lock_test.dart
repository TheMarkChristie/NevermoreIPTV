// A preset's login locked with its code (0.7.6). The fixture was locked by tools/make_house_presets.py's Python
// (hashlib.scrypt and cryptography's AESGCM), so this proves the two sides agree. Run: flutter test
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nevermore_iptv/core/preset_lock.dart';
import 'package:nevermore_iptv/core/presets.dart';

const _lock = {
  'kdf': 'scrypt',
  'n': 16384,
  'r': 8,
  'p': 1,
  'len': 8,
  'cipher': 'aes-256-gcm',
  'salt': 'AAECAwQFBgcICQoLDA0ODw==',
  'nonce': 'AAECAwQFBgcICQoL',
  'data': 'VMUZ5ZVBepZnB9m2k4Y/HooCTwuG3Arcgl7rbKeLh7iVxVKb++mo/rEzmiAAvQtjcSFcMwCI',
};

void main() {
  test('the code opens the lock the Python builder made; anything else does not', () async {
    final lock = PresetLock.fromJson(_lock)!;
    final login = unlockPresetSync(lock, '12345678')!;
    expect(login.username, 'u1');
    expect(login.password, 'p w!');
    expect(unlockPresetSync(lock, '12345679'), isNull);
    expect(await unlockPreset(lock, '12345678'), isNotNull);
    expect(PresetLock.fromJson({..._lock, 'kdf': 'pbkdf2'}), isNull);
  });

  test('a locked preset is found by its code, a plain one by its code, nothing by a wrong one', () async {
    final presets = presetsFromJson({
      'presets': [
        {'code': '4242', 'name': 'Plain', 'groups': []},
        {'name': 'Locked', 'server': 'http://h:80', 'groups': [], 'lock': _lock},
      ],
    });
    expect(presets[1].code, isNull);
    expect(presets[1].lock, isNotNull);
    expect((await presetForCode(presets, '4242'))!.$1.name, 'Plain');
    final locked = (await presetForCode(presets, '12345678'))!;
    expect(locked.$1.name, 'Locked');
    expect(locked.$2!.username, 'u1');
    expect(await presetForCode(presets, '00000000'), isNull);
    expect(await presetForCode(presets, ''), isNull);
  });

  test('the Dart lock round-trips, for the tests of what the TV does with it', () {
    final made = lockPreset('777777', const PresetLogin('a', 'b'), salt: Uint8List(16), nonce: Uint8List(12));
    expect(made.length, 6);
    expect(unlockPresetSync(made, '777777')!.password, 'b');
    expect(unlockPresetSync(made, '777778'), isNull);
    expect(jsonEncode(base64Encode(made.data)), isNotEmpty);
  });
}
