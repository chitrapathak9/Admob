import 'package:flutter/material.dart' show Color;

import 'app_constants.dart';

/// Backward-compatibility shim. [AppConstants] is the canonical source of truth
/// (Phase F2.1); existing services reference [AppConfig], so it now delegates to
/// [AppConstants] to keep a single set of values.
class AppConfig {
  static const String baseUrl = AppConstants.backendBase;
  static const String configPath = AppConstants.configPath;
  static const String healthPath = AppConstants.healthPath;
  static const String xmdsVersion = AppConstants.xmdsVersion;
  static const String clientType = AppConstants.clientType;
  static const String clientVersion = AppConstants.clientVersion;
  static const String clientCode = AppConstants.clientCode;
  static const int chunkSize = AppConstants.chunkSize;
  static const int heartbeatIntervalSeconds = AppConstants.heartbeatSeconds;
  static const int splashDelaySeconds = AppConstants.splashDelaySeconds;
  static const int xmrPingIntervalSeconds = AppConstants.xmrPingSeconds;

  static const Color background = AppConstants.background;
  static const Color accentOrange = AppConstants.accentOrange;
}
