import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../core/logger.dart';
import '../models/player_config.dart';
import 'storage_service.dart';

/// Thrown when /player/config is unreachable AND no cached config exists.
class ConfigUnavailableException implements Exception {
  final String message;
  const ConfigUnavailableException(this.message);
  @override
  String toString() => 'ConfigUnavailableException: $message';
}

/// Fetches player configuration from the backend (Phase F2.3).
///
/// On network failure: loads the last-known config from [StorageService].
/// If no cache exists either, throws [ConfigUnavailableException].
class ConfigService {
  ConfigService._();
  static final ConfigService instance = ConfigService._();

  final Dio _dio = Dio(
    BaseOptions(
      baseUrl: AppConfig.baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  /// Fetches /player/config, persists it, and returns [PlayerConfig].
  ///
  /// On any failure: tries the cached config from storage.
  /// Throws [ConfigUnavailableException] only when there is no cache.
  Future<PlayerConfig> fetchConfig() async {
    try {
      PlayerLogger.log('CONFIG', 'fetchConfig → GET ${AppConfig.configPath}');
      final response = await _dio.get(AppConfig.configPath);
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw Exception('Invalid config response type: ${data.runtimeType}');
      }
      if (data['success'] != true) {
        throw Exception(data['message']?.toString() ?? 'Config fetch failed');
      }
      final config = PlayerConfig.fromJson(data);
      await StorageService.instance.saveConfig(config);
      PlayerLogger.log('CONFIG', 'fetchConfig success', data: {
        'xmds': config.xmdsUrl,
        'xmr': config.xmrUrl,
        'interval': config.collectionInterval,
      });
      return config;
    } catch (e, st) {
      PlayerLogger.error('CONFIG', 'fetchConfig failed — trying cache', e, st);
      final cached = await StorageService.instance.loadConfig();
      if (cached != null) {
        PlayerLogger.log('CONFIG', 'Using cached config', data: {'xmds': cached.xmdsUrl});
        return cached;
      }
      throw ConfigUnavailableException('No network and no cached config: $e');
    }
  }

  /// Quick liveness check — returns true when the backend responds with
  /// `{"status":"ok"}`. Timeout is 10 s. Never throws.
  Future<bool> checkHealth() async {
    try {
      final response = await _dio
          .get(
            AppConfig.healthPath,
            options: Options(
              receiveTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
            ),
          )
          .timeout(const Duration(seconds: 10));
      final data = response.data;
      final ok = data is Map && data['status'] == 'ok';
      PlayerLogger.log('CONFIG', 'health=${ok ? "ok" : "fail"}');
      return ok;
    } catch (e) {
      PlayerLogger.error('CONFIG', 'checkHealth failed', e);
      return false;
    }
  }
}
