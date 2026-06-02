import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../utils/app_logger.dart';

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

	XmrCallback? onCollectNow;
	XmrCallback? onRevertToSchedule;
	XmrCallback? onScreenshot;

	Future<void> connect(String xmrUrl) async {
		_disposed = false;
		AppLogger.xmr('connect url=$xmrUrl');
		await _connectInternal(xmrUrl);
	}

	Future<void> _connectInternal(String xmrUrl) async {
		if (_disposed) return;
		try {
			await disconnect();
			_channel = WebSocketChannel.connect(Uri.parse(xmrUrl));
			_subscription = _channel!.stream.listen(
				_handleMessage,
				onError: (e) {
					AppLogger.apiError('XMR', 'stream error', e);
					_scheduleReconnect(xmrUrl);
				},
				onDone: () {
					AppLogger.xmr('connection closed — scheduling reconnect');
					_scheduleReconnect(xmrUrl);
				},
				cancelOnError: false,
			);
			_backoffSeconds = 1;
			_startPing();
			AppLogger.xmr('connected OK');
		} catch (e, st) {
			AppLogger.apiError('XMR', 'connect failed', e, st);
			_scheduleReconnect(xmrUrl);
		}
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
					onScreenshot?.call();
					break;
			}
		} catch (e, st) {
			AppLogger.apiError('XMR', 'failed to parse message', e, st);
		}
	}

	void _startPing() {
		_pingTimer?.cancel();
		_pingTimer = Timer.periodic(const Duration(seconds: 60), (_) {
			try {
				AppLogger.xmr('→ ping');
				_channel?.sink.add(jsonEncode({'type': 'ping'}));
			} catch (e) {
				AppLogger.apiError('XMR', 'ping failed', e);
			}
		});
	}

	void _scheduleReconnect(String xmrUrl) {
		if (_disposed) return;
		_reconnectTimer?.cancel();
		AppLogger.xmr('reconnect in ${_backoffSeconds}s');
		_reconnectTimer = Timer(Duration(seconds: _backoffSeconds), () {
			_backoffSeconds = (_backoffSeconds * 2).clamp(1, 60);
			_connectInternal(xmrUrl);
		});
	}

	Future<void> disconnect() async {
		AppLogger.xmr('disconnect');
		_pingTimer?.cancel();
		_pingTimer = null;
		_reconnectTimer?.cancel();
		_reconnectTimer = null;
		await _subscription?.cancel();
		_subscription = null;
		await _channel?.sink.close();
		_channel = null;
	}

	Future<void> dispose() async {
		_disposed = true;
		await disconnect();
	}
}
