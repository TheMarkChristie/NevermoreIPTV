/// The Android side's channel (MainActivity.kt): a source handed in by tools\install.ps1 through the Setup entry, and
/// the device's model and Android version.
library;

import 'package:flutter/services.dart';

const setupChannel = MethodChannel('nevermore/setup');

Future<Map<Object?, Object?>?> takeSetup() async {
  try {
    return await setupChannel.invokeMethod<Map<Object?, Object?>>('take');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
