import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/app_config.dart';
import '../utils/app_logger.dart';
import '../utils/websocket_url.dart';

typedef XmrCallback = void Function();

class XmrService {
	XmrService._();
	static final XmrService instance = XmrService._();

	WebSocketChannel? _channel;
	StreamSubscription? _subscription;
	Timer? _pingTimer;
	Timer? _reconnectTimer;
	int _backoffSeconds = 1;
	bool _disposed = false;
	bool _connecting = false;
	bool _connected = false;
	bool _reconnectStopped = false;
	String? _xmrUrl;

	XmrCallback? onCollectNow;
	XmrCallback? onRevertToSchedule;
	XmrCallback? onScreenshot;

	Future<void> connect(String xmrUrl) async {
		if (xmrUrl.trim().isEmpty) {
			AppLogger.xmr('Skipped — empty XMR URL');
			return;
		}
		if (_connected && _xmrUrl == xmrUrl.trim()) {
			AppLogger.xmr('Already connected — skip');
			return;
		}

		_disposed = false;
		_reconnectStopped = false;
		_xmrUrl = xmrUrl.trim();
		_backoffSeconds = 1;
		AppLogger.xmr('connect url=$_xmrUrl');
		await _connectInternal();
	}

	Future<void> _connectInternal() async {
		if (_disposed || _reconnectStopped || _connecting) return;
		final xmrUrl = _xmrUrl;
		if (xmrUrl == null || xmrUrl.isEmpty) return;

		_connecting = true;
		try {
			await _tearDownChannel();

			final uri = normalizeWebSocketUri(xmrUrl);
			AppLogger.xmr('connect uri=$uri');

			final channel = WebSocketChannel.connect(uri);
			await channel.ready.timeout(const Duration(seconds: 15));

			_channel = channel;
			_connected = true;
			_subscription = _channel!.stream.listen(
				_handleMessage,
				onError: (e) {
					AppLogger.apiError('XMR', 'stream error', e);
					_handleFailure(e);
				},
				onDone: () {
					if (_reconnectStopped || _disposed) return;
					AppLogger.xmr('connection closed');
					_handleFailure(null);
				},
				cancelOnError: true,
			);

			_backoffSeconds = 1;
			_startPing();
			AppLogger.xmr('connected OK uri=$uri');
		} catch (e, st) {
			AppLogger.apiError('XMR', 'connect failed', e, st);
			_handleFailure(e, st);
		} finally {
			_connecting = false;
		}
	}

	/// Errors that indicate a fundamentally broken URL — reconnect will never
	/// succeed until the config changes, so we stop trying.
	bool _isPermanentFailure(Object? error) {
		final errStr = error?.toString() ?? '';
		return errStr.contains(':0/') ||
			errStr.contains('Invalid WebSocket URL');
	}

	/// HTTP 404/403 from the server can happen during rolling deploys or
	/// restarts.  Rather than dying forever, we treat them as *transient* but
	/// use a longer back-off so we don't hammer a server that is intentionally
	/// rejecting us.
	static const int _transientServerErrorBackoffSeconds = 300; // 5 min

	bool _isTransientServerError(Object? error) {
		final errStr = error?.toString() ?? '';
		return errStr.contains('404') ||
			errStr.contains('403') ||
			errStr.contains('not upgraded');
	}

	void _handleFailure(Object? error, [StackTrace? stack]) {
		_connected = false;
		unawaited(_tearDownChannel());

		if (_isPermanentFailure(error)) {
			_reconnectStopped = true;
			_reconnectTimer?.cancel();
			_reconnectTimer = null;
			AppLogger.xmr(
				'Permanent failure — reconnect stopped. '
				'Check XMR URL from server config/connect response. '
				'cause=${error ?? "connection closed"}',
			);
			return;
		}

		if (_isTransientServerError(error)) {
			// Use a longer ceiling so we don't flood the server, but do keep
			// retrying so push commands resume once the server is back.
			_backoffSeconds = _backoffSeconds.clamp(
				_transientServerErrorBackoffSeconds,
				_transientServerErrorBackoffSeconds,
			);
			AppLogger.xmr(
				'Transient server error — will retry in ${_backoffSeconds}s. '
				'cause=${error ?? "connection closed"}',
			);
		}

		_scheduleReconnect();
	}

	void _handleMessage(dynamic message) {
		try {
			final str = message is String ? message : utf8.decode(message as List<int>);
			AppLogger.xmr('← message: ${AppLogger.truncate(str, max: 300)}');
			final cmd = jsonDecode(str) as Map<String, dynamic>;
			final action = cmd['action'] ?? cmd['type'];
			AppLogger.xmr('  action=$action');
			switch (action) {
				case 'collectNow':
					onCollectNow?.call();
					break;
				case 'revertToSchedule':
					onRevertToSchedule?.call();
					break;
				case 'screenShot':
				case 'screenshot':
				case 'requestScreenShot':
				case 'requestScreenshot':
					AppLogger.screenshotEventReceived('XMR', action.toString(), cmd);
					onScreenshot?.call();
					break;
			}
		} catch (e, st) {
			AppLogger.apiError('XMR', 'failed to parse message', e, st);
		}
	}

	void _startPing() {
		_pingTimer?.cancel();
		_pingTimer = Timer.periodic(
			const Duration(seconds: AppConfig.xmrPingIntervalSeconds),
			(_) {
				if (!_connected || _channel == null) return;
				try {
					AppLogger.xmr('→ ping');
					_channel!.sink.add(jsonEncode({'type': 'ping'}));
				} catch (e) {
					AppLogger.apiError('XMR', 'ping failed', e);
				}
			},
		);
	}

	void _scheduleReconnect() {
		if (_disposed || _reconnectStopped || _connecting) return;
		_reconnectTimer?.cancel();
		AppLogger.xmr('reconnect in ${_backoffSeconds}s');
		_reconnectTimer = Timer(Duration(seconds: _backoffSeconds), () {
			if (_disposed || _reconnectStopped) return;
			_backoffSeconds = (_backoffSeconds * 2).clamp(1, AppConfig.xmrReconnectMaxSeconds);
			unawaited(_connectInternal());
		});
	}

	Future<void> _tearDownChannel() async {
		_pingTimer?.cancel();
		_pingTimer = null;
		_reconnectTimer?.cancel();
		_reconnectTimer = null;
		await _subscription?.cancel();
		_subscription = null;
		try {
			await _channel?.sink.close();
		} catch (_) {}
		_channel = null;
		_connected = false;
	}

	Future<void> disconnect() async {
		AppLogger.xmr('disconnect');
		_reconnectStopped = true;
		_reconnectTimer?.cancel();
		_reconnectTimer = null;
		await _tearDownChannel();
	}

	Future<void> dispose() async {
		_disposed = true;
		await disconnect();
	}
}
