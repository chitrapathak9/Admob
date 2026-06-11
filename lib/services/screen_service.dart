import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/screen_connect_data.dart';
import '../models/screen_status_data.dart';
import '../utils/api_log_interceptor.dart';
import '../utils/app_logger.dart';
import '../utils/registration_errors.dart';

class ScreenApiException implements Exception {
	final String code;
	final String message;

	const ScreenApiException({required this.code, required this.message});

	bool get isNotRegistered =>
		RegistrationErrors.isNotRegistered(code: code, message: message);

	@override
	String toString() => message;
}

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

	void updateBaseUrl() {
		_dio.options.baseUrl = AppConfig.baseUrl;
	}

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
				final code = data['code']?.toString() ?? 'UNKNOWN';
				final msg = data['message']?.toString() ?? 'Status fetch failed';
				AppLogger.apiError('Status', 'success=false code=$code message=$msg');
				throw ScreenApiException(code: code, message: msg);
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
			if (body is Map) {
				throw ScreenApiException(
					code: body['code']?.toString() ?? 'NETWORK',
					message: body['message']?.toString() ??
						e.message ??
						'Network error fetching screen status',
				);
			}
			throw Exception(e.message ?? 'Network error fetching screen status');
		}
	}

	/// POST /api/v1/screens/screenshot — multipart PNG upload after socket event.
	Future<bool> uploadScreenshot({
		required String hardwareKey,
		required List<int> pngBytes,
		String? requestId,
	}) async {
		AppLogger.screenApi(
			'→ POST ${AppConfig.screensScreenshotPath} '
			'hardwareKey=$hardwareKey bytes=${pngBytes.length} '
			'requestId=${requestId ?? "(none)"}',
		);

		try {
			final formData = FormData.fromMap({
				'hardwareKey': hardwareKey,
				'clientType': AppConfig.clientType,
				'clientVersion': AppConfig.clientVersion,
				'capturedAt': DateTime.now().toUtc().toIso8601String(),
				if (requestId != null && requestId.isNotEmpty) 'requestId': requestId,
				'screenshot': MultipartFile.fromBytes(
					pngBytes,
					filename: 'screenshot.png',
					contentType: DioMediaType('image', 'png'),
				),
			});

			final response = await _dio.post<Map<String, dynamic>>(
				AppConfig.screensScreenshotPath,
				data: formData,
				options: Options(contentType: 'multipart/form-data'),
			);

			final data = response.data;
			if (data?['success'] == true) {
				AppLogger.screenApi('← SUCCESS response=${AppLogger.sanitizeBody(data)}');
				return true;
			}

			final msg = data?['message']?.toString() ?? 'Screenshot upload failed';
			AppLogger.screenApiError('← FAILED success=false message=$msg');
			return false;
		} on DioException catch (e, st) {
			AppLogger.screenApiError('← FAILED network error', e, st);
			return false;
		}
	}

	Future<bool> sendStorageInfo({
		required String hardwareKey,
		required int usedMb,
		required int totalMb,
		required int freeMb,
	}) async {
		AppLogger.screenApi('→ POST /api/v1/screens/storage/info hardwareKey=$hardwareKey usedMb=$usedMb');
		try {
			final response = await _dio.post<Map<String, dynamic>>(
				'/api/v1/screens/storage/info',
				data: {
					'hardwareKey': hardwareKey,
					'usedMb': usedMb,
					'totalMb': totalMb,
					'freeMb': freeMb,
				},
			);
			return response.data?['success'] == true;
		} catch (e, st) {
			AppLogger.screenApiError('← FAILED sendStorageInfo network error', e, st);
			return false;
		}
	}

	Future<bool> sendStorageClear({
		required String hardwareKey,
		required int freedMb,
	}) async {
		AppLogger.screenApi('→ POST /api/v1/screens/storage/clear hardwareKey=$hardwareKey freedMb=$freedMb');
		try {
			final response = await _dio.post<Map<String, dynamic>>(
				'/api/v1/screens/storage/clear',
				data: {
					'hardwareKey': hardwareKey,
					'freedMb': freedMb,
				},
			);
			return response.data?['success'] == true;
		} catch (e, st) {
			AppLogger.screenApiError('← FAILED sendStorageClear network error', e, st);
			return false;
		}
	}
}
