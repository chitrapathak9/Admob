import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

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
		await _connectInternal(xmrUrl);
	}

	Future<void> _connectInternal(String xmrUrl) async {
		if (_disposed) return;
		try {
			await disconnect();
			_channel = WebSocketChannel.connect(Uri.parse(xmrUrl));
			_subscription = _channel!.stream.listen(
				_handleMessage,
				onError: (_) => _scheduleReconnect(xmrUrl),
				onDone: () => _scheduleReconnect(xmrUrl),
				cancelOnError: false,
			);
			_backoffSeconds = 1;
			_startPing();
		} catch (_) {
			_scheduleReconnect(xmrUrl);
		}
	}

	void _handleMessage(dynamic message) {
		try {
			final str = message is String ? message : utf8.decode(message as List<int>);
			final cmd = jsonDecode(str) as Map<String, dynamic>;
			final action = cmd['action'] ?? cmd['type'];
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
		} catch (_) {}
	}

	void _startPing() {
		_pingTimer?.cancel();
		_pingTimer = Timer.periodic(const Duration(seconds: 60), (_) {
			try {
				_channel?.sink.add(jsonEncode({'type': 'ping'}));
			} catch (_) {}
		});
	}

	void _scheduleReconnect(String xmrUrl) {
		if (_disposed) return;
		_reconnectTimer?.cancel();
		_reconnectTimer = Timer(Duration(seconds: _backoffSeconds), () {
			_backoffSeconds = (_backoffSeconds * 2).clamp(1, 60);
			_connectInternal(xmrUrl);
		});
	}

	Future<void> disconnect() async {
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
