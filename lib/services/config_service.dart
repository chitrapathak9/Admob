import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/player_config.dart';
import '../utils/api_log_interceptor.dart';
import '../utils/app_logger.dart';
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
	)..interceptors.add(ApiLogInterceptor());

	Future<PlayerConfig> fetchConfig() async {
		AppLogger.config('fetchConfig');

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
			AppLogger.config(
				'OK xmdsUrl=${config.xmdsUrl} xmrUrl=${config.xmrUrl} '
				'cmsKey=${AppLogger.maskSecret(config.cmsKey)} '
				'collectionInterval=${config.collectionInterval}',
			);
			return config;
		} on DioException catch (e, st) {
			AppLogger.apiError('Config', 'fetchConfig failed', e, st);
			throw Exception(e.message ?? 'Network error fetching config');
		}
	}
}
