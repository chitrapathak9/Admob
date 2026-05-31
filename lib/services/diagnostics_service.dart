import 'package:dio/dio.dart';

import '../config/app_constants.dart';
import '../core/logger.dart';

/// Result of GET /api/v1/player/status/:hardwareKey (Phase B1.4 backend).
class PlayerStatus {
  final String status; // not_found | pending | active | error
  final int? displayId;
  final String? displayName;
  final bool authorised;
  final int groupCount;
  final bool hasSchedule;
  final String message;

  const PlayerStatus({
    required this.status,
    this.displayId,
    this.displayName,
    this.authorised = false,
    this.groupCount = 0,
    this.hasSchedule = false,
    this.message = '',
  });

  bool get isActive => status == 'active';
  bool get isPending => status == 'pending';
  bool get isNotFound => status == 'not_found';
  bool get isError => status == 'error';

  factory PlayerStatus.fromData(Map<String, dynamic> data) => PlayerStatus(
        status: (data['status'] ?? 'error').toString(),
        displayId: (data['displayId'] as num?)?.toInt(),
        displayName: data['displayName']?.toString(),
        authorised: data['authorised'] == true,
        groupCount: (data['groupCount'] as num?)?.toInt() ?? 0,
        hasSchedule: data['hasSchedule'] == true,
        message: data['message']?.toString() ?? '',
      );

  static const PlayerStatus unreachable =
      PlayerStatus(status: 'error', message: 'CMS unreachable');
}

/// Calls the backend player status + diagnostics endpoints (Phase F2.6/F2.7).
/// These are the public, no-auth endpoints added in backend B1.2/B1.4.
class DiagnosticsService {
  DiagnosticsService._();
  static final DiagnosticsService instance = DiagnosticsService._();

  final Dio _dio = Dio(BaseOptions(
    baseUrl: AppConstants.backendBase,
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
  ));

  /// Poll registration/approval status. Never throws — returns
  /// [PlayerStatus.unreachable] on any failure so the controller keeps polling.
  Future<PlayerStatus> checkStatus(String hardwareKey) async {
    try {
      final res = await _dio.get('${AppConstants.statusPath}/$hardwareKey');
      final body = res.data;
      if (body is Map && body['data'] is Map) {
        return PlayerStatus.fromData(
          (body['data'] as Map).cast<String, dynamic>(),
        );
      }
      return PlayerStatus.unreachable;
    } catch (e) {
      PlayerLogger.error('CONFIG', 'status check failed', e);
      return PlayerStatus.unreachable;
    }
  }

  /// Fetch the full diagnostics report for the error/no-content screens.
  /// Returns the `data` object, or null on failure.
  Future<Map<String, dynamic>?> fetchDiagnostics(String hardwareKey) async {
    try {
      final res = await _dio.get('${AppConstants.diagnosticsPath}/$hardwareKey');
      final body = res.data;
      if (body is Map && body['data'] is Map) {
        return (body['data'] as Map).cast<String, dynamic>();
      }
      return null;
    } catch (e) {
      PlayerLogger.error('CONFIG', 'diagnostics fetch failed', e);
      return null;
    }
  }
}
