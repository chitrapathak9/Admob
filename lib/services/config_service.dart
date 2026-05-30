import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/player_config.dart';
import 'storage_service.dart';

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

  Future<PlayerConfig> fetchConfig() async {
    try {
      final response = await _dio.get(AppConfig.configPath);
      final data = response.data;
      if (data is! Map<String, dynamic>) {
        throw Exception('Invalid config response');
      }
      if (data['success'] != true) {
        throw Exception(data['message']?.toString() ?? 'Config fetch failed');
      }
      final config = PlayerConfig.fromJson(data);
      await StorageService.instance.saveConfig(config);
      return config;
    } on DioException catch (e) {
      throw Exception(e.message ?? 'Network error fetching config');
    }
  }
}
