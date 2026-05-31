import 'package:flutter/material.dart' show Color;

/// Single source of truth for every hardcoded value in the player.
/// New code (controller, state machine, screens) reads from here.
class AppConstants {
  // ── Backend ─────────────────────────────────────────────────────────────────
  static const String backendBase = 'https://xibo-be.yourpreview.space';
  static const String configPath = '/api/v1/player/config';
  static const String healthPath = '/api/v1/player/health';
  static const String statusPath = '/api/v1/player/status'; // + /:hardwareKey
  static const String diagnosticsPath = '/api/v1/player/diagnostics'; // + /:hardwareKey

  // ── XMDS client identity ────────────────────────────────────────────────────
  static const String xmdsVersion = '5';
  static const String clientType = 'flutter';
  static const String clientVersion = '1.0.0';
  static const String clientCode = '100';

  // ── Timing ──────────────────────────────────────────────────────────────────
  static const int statusPollIntervalSeconds = 15;
  static const int scheduleRefreshSeconds = 60;
  static const int heartbeatSeconds = 30;
  static const int xmrPingSeconds = 60;
  static const int errorBackoffSeconds = 30;
  static const int maxErrorBackoffSeconds = 300;
  static const int downloadTimeoutSeconds = 120;
  static const int proxyTimeoutSeconds = 45;
  static const int splashDelaySeconds = 2;
  static const int chunkSize = 512000;

  // ── File classification ─────────────────────────────────────────────────────
  static const List<String> skipExtensions = ['otf', 'ttf', 'woff', 'woff2', 'js', 'css'];
  static const List<String> mediaExtensions = [
    'jpg', 'jpeg', 'png', 'gif', 'bmp', 'mp4', 'avi', 'mov', 'webm',
  ];

  // ── Theme ───────────────────────────────────────────────────────────────────
  static const Color background = Color(0xFF000000);
  static const Color accentOrange = Color(0xFFF97316);
  static const Color textWhite = Color(0xFFFFFFFF);
}
