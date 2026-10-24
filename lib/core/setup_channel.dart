/// The Android side's channel (MainActivity.kt): a source handed in by tools\install.ps1 through the Setup entry, and
/// the device's model and Android version. A setup that arrives while the app is open comes the other way, through
/// [listenForSetups].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const setupChannel = MethodChannel('nevermore/setup');

/// A line about a setup just applied, for the watch screen to show for a few seconds ("Set up from the install script:
/// My provider"). Set to null and then the text, so the same line twice is still shown twice.
final setupNotices = ValueNotifier<String?>(null);

Future<Map<Object?, Object?>?> takeSetup() async {
  try {
    return await setupChannel.invokeMethod<Map<Object?, Object?>>('take');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// Setups that arrive while the app is open (an adb command without -S reaches MainActivity's onNewIntent) go to
/// [apply] instead of waiting for a start that never comes.
void listenForSetups(Future<void> Function(Map<Object?, Object?> setup) apply) {
  setupChannel.setMethodCallHandler((call) async {
    final args = call.arguments;
    if (call.method == 'setup' && args is Map) await apply(Map<Object?, Object?>.from(args));
    return null;
  });
}
