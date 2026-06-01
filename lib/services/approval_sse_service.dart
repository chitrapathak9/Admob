import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../config/app_constants.dart';
import '../core/logger.dart';

// ── Public types ───────────────────────────────────────────────────────────────

enum SseConnectionState { disconnected, connecting, connected, reconnecting }

/// A single server-sent event from the approval stream.
class ApprovalSseEvent {
  final String type; // connected | approved | expired | timeout | message
  final Map<String, dynamic> data;

  const ApprovalSseEvent(this.type, this.data);

  bool get isApproved  => type == 'approved';
  bool get isExpired   => type == 'expired';
  bool get isTimeout   => type == 'timeout';
  bool get isConnected => type == 'connected';

  @override
  String toString() => 'SseEvent($type, $data)';
}

// ── Service ────────────────────────────────────────────────────────────────────

/// Connects to GET /api/v1/player/approval-stream/:hardwareKey.
///
/// The server holds the connection open and emits:
///   connected — stream ready (sent immediately on open)
///   approved  — admin approved; carry on immediately, no restart needed
///   expired   — pairing code timed out (15 min); device should show retry UI
///   timeout   — 30 min elapsed without approval
///   : ping    — SSE keepalive comment every 25 s (transparent to this parser)
///
/// Behaviour:
///   • Auto-reconnects on network failure with exponential back-off (3 s → 60 s).
///   • After receiving `approved`, the stream closes and reconnection stops.
///   • [disconnect] is safe to call from any state — it cancels inflight work.
///   • [dispose] is called once on full app shutdown (closes stream controllers).
class ApprovalSseService {
  ApprovalSseService._();
  static final ApprovalSseService instance = ApprovalSseService._();

  // ── Streams ────────────────────────────────────────────────────────────────
  final _eventController = StreamController<ApprovalSseEvent>.broadcast();
  final _stateController = StreamController<SseConnectionState>.broadcast();

  Stream<ApprovalSseEvent> get events          => _eventController.stream;
  Stream<SseConnectionState> get stateChanges  => _stateController.stream;

  // ── State ──────────────────────────────────────────────────────────────────
  SseConnectionState _state = SseConnectionState.disconnected;
  SseConnectionState get connectionState => _state;

  CancelToken? _cancelToken;
  Timer?       _reconnectTimer;
  String?      _hardwareKey;
  bool         _disposed          = false;
  bool         _approvalReceived  = false;
  int          _backoffSeconds    = 3;

  // ── Public API ─────────────────────────────────────────────────────────────

  void connect(String hardwareKey) {
    if (_disposed) return;
    _approvalReceived = false;
    _backoffSeconds   = 3;
    _hardwareKey      = hardwareKey;

    _cancelToken?.cancel('reconnect');
    _reconnectTimer?.cancel();
    _setState(SseConnectionState.connecting);
    _doConnect(hardwareKey);
  }

  void disconnect() {
    _cancelToken?.cancel('disconnect');
    _reconnectTimer?.cancel();
    _cancelToken     = null;
    _reconnectTimer  = null;
    _hardwareKey     = null;
    _setState(SseConnectionState.disconnected);
  }

  void dispose() {
    _disposed = true;
    disconnect();
    _eventController.close();
    _stateController.close();
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  void _setState(SseConnectionState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  Future<void> _doConnect(String hardwareKey) async {
    if (_disposed || _approvalReceived) return;

    final url = '${AppConstants.backendBase}'
        '${AppConstants.approvalStreamPath}/$hardwareKey';

    _cancelToken = CancelToken();

    try {
      PlayerLogger.log('SSE', 'Connecting → $url');

      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 30),
          // No receiveTimeout: SSE is long-lived; server pings every 25 s so
          // silence doesn't mean the connection is dead.
          headers: {
            'Accept':        'text/event-stream',
            'Cache-Control': 'no-cache',
          },
        ),
      );

      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: _cancelToken,
        options: Options(responseType: ResponseType.stream),
      );

      _setState(SseConnectionState.connected);
      _backoffSeconds = 3; // reset back-off after clean connect

      final stream = response.data!.stream;
      String buffer            = '';
      String pendingEventType  = '';

      await for (final chunk in stream) {
        if (_disposed || _approvalReceived) break;

        buffer += utf8.decode(chunk, allowMalformed: true);

        // Process all complete lines from the buffer.
        while (true) {
          final nl = buffer.indexOf('\n');
          if (nl == -1) break;

          final line = buffer.substring(0, nl).trimRight(); // strip \r on Windows
          buffer = buffer.substring(nl + 1);

          if (line.isEmpty) {
            // Empty line: event boundary — reset pending type.
            pendingEventType = '';
          } else if (line.startsWith(':')) {
            // SSE comment / keepalive — intentionally ignored.
          } else if (line.startsWith('event:')) {
            pendingEventType = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            final rawData = line.substring(5).trim();
            final type    = pendingEventType.isEmpty ? 'message' : pendingEventType;
            _dispatch(type, rawData);
            if (type == 'approved') break; // stop processing after approval
          }
        }

        if (_approvalReceived) break;
      }

      // Server closed the connection cleanly (after approved / expired / timeout).
      if (!_disposed && !_approvalReceived) {
        PlayerLogger.log('SSE', 'Stream ended by server — will reconnect');
        _scheduleReconnect(hardwareKey);
      }
    } on DioException catch (e) {
      if (_disposed || _approvalReceived) return;
      if (_cancelToken?.isCancelled == true) return;
      PlayerLogger.error('SSE', 'Connection error (${e.type})', e);
      _setState(SseConnectionState.reconnecting);
      _scheduleReconnect(hardwareKey);
    } catch (e, st) {
      if (_disposed || _approvalReceived) return;
      PlayerLogger.error('SSE', 'Unexpected error', e, st);
      _setState(SseConnectionState.reconnecting);
      _scheduleReconnect(hardwareKey);
    }
  }

  void _dispatch(String type, String rawData) {
    Map<String, dynamic> data = {};
    try {
      final decoded = jsonDecode(rawData);
      if (decoded is Map) data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      data = {'raw': rawData};
    }

    final event = ApprovalSseEvent(type, data);
    PlayerLogger.log('SSE', 'event=$type', data: data);

    if (event.isApproved) _approvalReceived = true;

    if (!_eventController.isClosed) _eventController.add(event);
  }

  void _scheduleReconnect(String hardwareKey) {
    if (_disposed || _approvalReceived) return;
    final delay = _backoffSeconds;
    _backoffSeconds = (_backoffSeconds * 2).clamp(3, 60);
    PlayerLogger.log('SSE', 'Reconnecting in ${delay}s');
    _reconnectTimer = Timer(Duration(seconds: delay), () {
      if (!_disposed && !_approvalReceived) _doConnect(hardwareKey);
    });
  }
}
