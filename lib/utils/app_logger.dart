import 'package:flutter/foundation.dart';

/// Tagged debug logs for all API calls. Filter in logcat / terminal, e.g.:
/// `adb logcat | grep -E '\[Connect\]|\[Manifest\]|\[XMDS\]'`
class AppLogger {
	AppLogger._();

	// Registration flow
	static void connect(String message) => _log('Connect', message);
	static void status(String message) => _log('Status', message);
	static void register(String message) => _log('RegisterDisplay', message);
	static void setup(String message) => _log('Setup', message);

	// Player / REST APIs
	static void config(String message) => _log('Config', message);
	static void manifest(String message) => _log('Manifest', message);
	static void heartbeat(String message) => _log('Heartbeat', message);
	static void health(String message) => _log('Health', message);

	// XMDS / media / realtime
	static void xmds(String message) => _log('XMDS', message);
	static void download(String message) => _log('Download', message);
	static void xmr(String message) => _log('XMR', message);

	static void api(String tag, String message) => _log(tag, message);

	static void connectError(String message, [Object? error, StackTrace? stack]) {
		_error('Connect', message, error, stack);
	}

	static void registerError(String message, [Object? error, StackTrace? stack]) {
		_error('RegisterDisplay', message, error, stack);
	}

	static void setupError(String message, [Object? error, StackTrace? stack]) {
		_error('Setup', message, error, stack);
	}

	static void apiError(String tag, String message, [Object? error, StackTrace? stack]) {
		_error(tag, message, error, stack);
	}

	static String maskSecret(String? value, {int visible = 4}) {
		if (value == null || value.isEmpty) return '(empty)';
		if (value.length <= visible) return '****';
		return '${value.substring(0, visible)}**** (${value.length} chars)';
	}

	static String truncate(String? value, {int max = 800}) {
		if (value == null) return '(null)';
		if (value.length <= max) return value;
		return '${value.substring(0, max)}… [${value.length} chars total]';
	}

	/// Masks secrets in JSON-like or SOAP request bodies before logging.
	static String sanitizeBody(Object? body) {
		if (body == null) return '(null)';
		var text = body.toString();
		text = text.replaceAllMapped(
			RegExp(r'"(cmsKey|serverKey|access_token)"\s*:\s*"([^"]*)"', caseSensitive: false),
			(m) => '"${m.group(1)}":"${maskSecret(m.group(2))}"',
		);
		text = text.replaceAllMapped(
			RegExp(r'<serverKey>([^<]*)</serverKey>', caseSensitive: false),
			(m) => '<serverKey>${maskSecret(m.group(1))}</serverKey>',
		);
		text = text.replaceAllMapped(
			RegExp(r'<cmsKey>([^<]*)</cmsKey>', caseSensitive: false),
			(m) => '<cmsKey>${maskSecret(m.group(1))}</cmsKey>',
		);
		return truncate(text);
	}

	static void _log(String tag, String message) {
		debugPrint('[$tag] $message');
	}

	static void _error(String tag, String message, Object? error, StackTrace? stack) {
		debugPrint('[$tag] ERROR: $message');
		if (error != null) debugPrint('[$tag]   cause: $error');
		if (stack != null) debugPrint('[$tag]   stack: $stack');
	}
}
