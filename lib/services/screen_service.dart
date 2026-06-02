import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/screen_connect_data.dart';
import '../models/screen_status_data.dart';
import '../utils/api_log_interceptor.dart';
import '../utils/app_logger.dart';

class ScreenService {
	ScreenService._();
	static final ScreenService instance = ScreenService._();

	final Dio _dio = Dio(
		BaseOptions(
			baseUrl: AppConfig.baseUrl,
			connectTimeout: const Duration(seconds: 30),
			receiveTimeout: const Duration(seconds: 30),
			headers: {'Content-Type': 'application/json'},
		),
	)..interceptors.add(ApiLogInterceptor());

	Future<ScreenConnectData> connect({
		required String hardwareKey,
		required String deviceName,
		String macAddress = '',
	}) async {
		final payload = {
			'hardwareKey': hardwareKey,
			'deviceName': deviceName,
			'clientType': AppConfig.clientType,
			'clientVersion': AppConfig.clientVersion,
			'macAddress': macAddress,
		};

		AppLogger.connect('connect hardwareKey=$hardwareKey deviceName="$deviceName"');

		try {
			final response = await _dio.post<Map<String, dynamic>>(
				AppConfig.screensConnectPath,
				data: payload,
			);

			final data = response.data;
			if (data == null) {
				throw Exception('Empty response from connect');
			}
			if (data['success'] != true) {
				final msg = data['message']?.toString() ?? 'Screen connect failed';
				AppLogger.connectError('success=false message=$msg');
				throw Exception(msg);
			}

			final result = ScreenConnectData.fromJson(data);
			AppLogger.connect(
				'OK deviceId=${result.deviceId} status=${result.status} '
				'cmsKey=${AppLogger.maskSecret(result.cmsKey)} expiresAt=${result.expiresAt}',
			);
			return result;
		} on DioException catch (e, st) {
			AppLogger.connectError('connect failed', e, st);
			final body = e.response?.data;
			if (body is Map && body['message'] != null) {
				throw Exception(body['message'].toString());
			}
			throw Exception(e.message ?? 'Network error connecting screen');
		} catch (e, st) {
			AppLogger.connectError('unexpected error', e, st);
			rethrow;
		}
	}

	Future<ScreenStatusData> getStatus(String hardwareKey) async {
		AppLogger.status('getStatus hardwareKey=$hardwareKey');

		try {
			final response = await _dio.get<Map<String, dynamic>>(
				'${AppConfig.screensStatusPath}/$hardwareKey',
			);

			final data = response.data;
			if (data == null) {
				throw Exception('Empty response from status');
			}
			if (data['success'] != true) {
				final msg = data['message']?.toString() ?? 'Status fetch failed';
				AppLogger.apiError('Status', 'success=false message=$msg');
				throw Exception(msg);
			}

			final result = ScreenStatusData.fromJson(data);
			AppLogger.status(
				'OK status=${result.status} xiboDisplayId=${result.xiboDisplayId} '
				'displayName="${result.displayName}"',
			);
			return result;
		} on DioException catch (e, st) {
			AppLogger.apiError('Status', 'getStatus failed', e, st);
			final body = e.response?.data;
			if (body is Map && body['message'] != null) {
				throw Exception(body['message'].toString());
			}
			throw Exception(e.message ?? 'Network error fetching screen status');
		}
	}
}
