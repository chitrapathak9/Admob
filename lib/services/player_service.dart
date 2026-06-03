import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../models/player_manifest.dart';
import '../utils/api_log_interceptor.dart';
import '../utils/app_logger.dart';
import 'storage_service.dart';

class PlayerApiException implements Exception {
	final String code;
	final String message;

	const PlayerApiException({required this.code, required this.message});

	@override
	String toString() => message;
}

class PlayerService {
	PlayerService._();
	static final PlayerService instance = PlayerService._();

	final Dio _dio = Dio(
		BaseOptions(
			baseUrl: AppConfig.baseUrl,
			connectTimeout: const Duration(seconds: 30),
			receiveTimeout: const Duration(seconds: 60),
			headers: {'Content-Type': 'application/json'},
		),
	)..interceptors.add(ApiLogInterceptor());

	Future<PlayerManifest> getManifest(String hardwareKey) async {
		AppLogger.manifest('getManifest hardwareKey=$hardwareKey');

		try {
			final response = await _dio.get<Map<String, dynamic>>(
				'${AppConfig.playerManifestPath}/$hardwareKey',
			);
			final data = response.data;
			if (data == null) {
				throw Exception('Empty response from manifest');
			}
			if (data['success'] != true) {
				throw PlayerApiException(
					code: data['code']?.toString() ?? 'UNKNOWN',
					message: data['message']?.toString() ?? 'Manifest fetch failed',
				);
			}

			final manifest = PlayerManifest.fromJson(data);
			AppLogger.manifest(
				'OK displayId=${manifest.displayId} displayName="${manifest.displayName}" '
				'manifestHash=${manifest.manifestHash} mediaCount=${manifest.media.length}',
			);
			return manifest;
		} on DioException catch (e, st) {
			AppLogger.apiError('Manifest', 'getManifest failed', e, st);
			final body = e.response?.data;
			if (body is Map) {
				throw PlayerApiException(
					code: body['code']?.toString() ?? 'NETWORK',
					message: body['message']?.toString() ?? e.message ?? 'Network error fetching manifest',
				);
			}
			throw Exception(e.message ?? 'Network error fetching manifest');
		} on PlayerApiException catch (e) {
			AppLogger.apiError('Manifest', 'code=${e.code} message=${e.message}');
			rethrow;
		}
	}

	Future<HeartbeatResult> sendHeartbeat({
		required String hardwareKey,
		required String status,
		String? currentFilename,
		String appVersion = AppConfig.clientVersion,
	}) async {
		AppLogger.heartbeat(
			'sendHeartbeat hardwareKey=$hardwareKey status=$status '
			'currentFilename=${currentFilename ?? "(none)"} appVersion=$appVersion',
		);

		try {
			final requestData = <String, dynamic>{
				'hardwareKey': hardwareKey,
				'status': status,
				'appVersion': appVersion,
			};
			if (currentFilename != null && currentFilename.isNotEmpty) {
				requestData['currentFilename'] = currentFilename;
			}

			final response = await _dio.post<Map<String, dynamic>>(
				AppConfig.playerHeartbeatPath,
				data: requestData,
			);
			final data = response.data;
			if (data == null || data['success'] != true) {
				AppLogger.heartbeat('OK action=continue (default — success not true)');
				return const HeartbeatResult(action: 'continue');
			}
			final responseData = data['data'] as Map<String, dynamic>? ?? {};
			final action = responseData['action'] as String? ?? 'continue';
			AppLogger.heartbeat('OK action=$action');
			return HeartbeatResult(action: action);
		} catch (e, st) {
			AppLogger.apiError('Heartbeat', 'sendHeartbeat failed (silent continue)', e, st);
			return const HeartbeatResult(action: 'continue');
		}
	}

	/// POST /api/v1/player/offline — must succeed before app disconnects on kill.
	/// Returns true when server responds with success: true.
	Future<bool> markScreenOffline() async {
		try {
			final hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
			AppLogger.offline(
				'→ POST ${AppConfig.playerOfflinePath} hardwareKey=$hardwareKey',
			);

			final response = await _dio.post<Map<String, dynamic>>(
				AppConfig.playerOfflinePath,
				data: {'hardwareKey': hardwareKey},
				options: Options(
					sendTimeout: Duration(seconds: AppConfig.offlineApiTimeoutSeconds),
					receiveTimeout: Duration(seconds: AppConfig.offlineApiTimeoutSeconds),
				),
			);

			final data = response.data;
			final success = data?['success'] == true;
			final message = data?['message']?.toString() ?? '';

			if (success) {
				AppLogger.offline('← SUCCESS — $message');
				return true;
			}

			AppLogger.offline('← FAILED — success!=true response=$data');
			return false;
		} catch (e, st) {
			AppLogger.apiError('Offline', '← FAILED — API error', e, st);
			return false;
		}
	}

	Future<bool> pingHealth() async {
		AppLogger.health('pingHealth');

		try {
			final response = await _dio.get(AppConfig.healthPath);
			final ok = response.statusCode == 200;
			AppLogger.health('OK reachable=$ok http=${response.statusCode}');
			return ok;
		} catch (e, st) {
			AppLogger.apiError('Health', 'pingHealth failed', e, st);
			return false;
		}
	}
}
