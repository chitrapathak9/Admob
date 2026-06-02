import 'package:flutter/material.dart' show Color;

class AppConfig {
  static const String baseUrl = 'https://xibo-be.yourpreview.space';
  static const String configPath = '/api/v1/player/config';
  static const String screensConnectPath = '/api/v1/screens/connect';
  static const String screensStatusPath = '/api/v1/screens/status';
  static const String playerManifestPath = '/api/v1/player/manifest';
  static const String playerHeartbeatPath = '/api/v1/player/heartbeat';
  static const String healthPath = '/api/v1/player/health';
  static const int screenStatusPollSeconds = 60;
  static const int connectRetrySeconds = 30;
  static const int connectMaxRetries = 3;
  static const int manifestRetrySeconds = 60;
  static const String xmdsVersion = '5';
  static const String clientType = 'flutter';
  static const String clientVersion = '1.0.0';
  static const String clientCode = '100';
  static const int chunkSize = 512000;
  static const int heartbeatIntervalSeconds = 300;
  static const int splashDelaySeconds = 2;
  static const int xmrPingIntervalSeconds = 60;

  static const Color background = Color(0xFF000000);
  static const Color accentOrange = Color(0xFFFF8C00);
}
