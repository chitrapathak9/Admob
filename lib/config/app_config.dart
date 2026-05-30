import 'package:flutter/material.dart' show Color;

class AppConfig {
  static const String baseUrl = 'https://xibo-be.yourpreview.space';
  static const String configPath = '/api/v1/player/config';
  static const String healthPath = '/api/v1/player/health';
  static const String xmdsVersion = '5';
  static const String clientType = 'flutter';
  static const String clientVersion = '1.0.0';
  static const String clientCode = '100';
  static const int chunkSize = 512000;
  static const int heartbeatIntervalSeconds = 30;
  static const int splashDelaySeconds = 2;
  static const int xmrPingIntervalSeconds = 60;

  static const Color background = Color(0xFF000000);
  static const Color accentOrange = Color(0xFFFF8C00);
}
