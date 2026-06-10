import 'package:flutter/material.dart' show Color;

class AppConfig {
  static const String defaultBaseUrl = 'https://xibo-be.yourpreview.space';
  static String _baseUrl = defaultBaseUrl;

  static String get baseUrl => _baseUrl;

  static void setRuntimeBaseUrl(String url) {
    _baseUrl = url;
  }

  static const String configPath = '/api/v1/player/config';
  static const String screensConnectPath = '/api/v1/screens/connect';
  static const String screensStatusPath = '/api/v1/screens/status';
  static const String playerManifestPath = '/api/v1/player/manifest';
  static const String playerHeartbeatPath = '/api/v1/player/heartbeat';
  static const String playerOfflinePath = '/api/v1/player/offline';
  static const String healthPath = '/api/v1/player/health';
  static const String screensScreenshotPath = '/api/v1/screens/screenshot';

  /// Socket.io event names that trigger a screenshot capture.
  static const List<String> screenshotSocketEvents = [
    'screen:screenshot',
    'screenshot:request',
    'screenshot',
    'screen:capture',
    'screen:request_screenshot',
    'player:screenshot',
    // Same action names as XMR (backend may emit these on Socket.io too).
    'requestScreenshot',
    'requestScreenShot',
    'screenShot',
  ];

  static bool isScreenshotSocketEvent(String name) {
    if (screenshotSocketEvents.contains(name)) return true;
    final lower = name.toLowerCase();
    return lower.contains('screenshot') ||
        lower.contains('screen_capture') ||
        lower == 'capture';
  }
  static const int screenStatusPollSeconds = 60;
  static const int connectRetrySeconds = 30;
  static const int connectMaxRetries = 3;
  static const int manifestRetrySeconds = 60;
  static const String xmdsVersion = '5';
  static const String clientType = 'flutter';
  static const String clientVersion = '1.0.0';
  static const String clientCode = '100';
  static const int chunkSize = 512000;
  static const int heartbeatIntervalSeconds = 60;
  static const int splashDelaySeconds = 2;
  static const int xmrPingIntervalSeconds = 60;
  static const int xmrReconnectMaxSeconds = 120;

  /// Socket.io: built-in reconnect cap and delays (ms).
  static const int socketReconnectAttempts = 999;
  static const int socketReconnectDelayMs = 3000;
  static const int socketReconnectDelayMaxMs = 120000;
  static const int socketBackoffBaseMs = 10000;
  static const int socketBackoffMaxMs = 300000;
  static const int socketMaxFailuresBeforePause = 5;
  static const int socketReconnectCatchUpCooldownSeconds = 45;

  /// Wait after offline socket emit + REST call so packets flush before disconnect.
  static const int offlineNotifyFlushMs = 500;

  /// Max wait for offline API during app kill (must finish before disconnect).
  static const int offlineApiTimeoutSeconds = 10;

  static const Color background = Color(0xFF000000);
  static const Color accentOrange = Color(0xFFFF8C00);
}
