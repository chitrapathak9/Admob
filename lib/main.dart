import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'app.dart';
import 'core/logger.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Catch all Flutter framework errors and log them (Phase F2.9).
  FlutterError.onError = (details) {
    PlayerLogger.error(
      'FLUTTER',
      details.exceptionAsString(),
      details.exception,
      details.stack,
    );
  };

  // Catch all async/platform errors so the player never dies silently.
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    PlayerLogger.error('PLATFORM', error.toString(), error, stack);
    return true;
  };

  // Full immersive kiosk mode + keep screen on (orientation follows device).
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  WakelockPlus.enable();

  runApp(const TheadbookPlayerApp());
}
