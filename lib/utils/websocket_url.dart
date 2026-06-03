/// Normalizes WebSocket URLs for [WebSocketChannel.connect].
///
/// Dart / web_socket_channel can produce invalid URLs like `https://host:0/path`
/// when no explicit port is given. Always use ws/wss with an explicit port.
Uri normalizeWebSocketUri(String url) {
	var trimmed = url.trim();
	if (trimmed.endsWith('/')) {
		trimmed = trimmed.substring(0, trimmed.length - 1);
	}

	var uri = Uri.tryParse(trimmed);
	if (uri == null || uri.host.isEmpty) {
		throw ArgumentError('Invalid WebSocket URL: $url');
	}

	if (uri.scheme.isEmpty) {
		uri = Uri.parse('wss://$trimmed');
	}

	var scheme = uri.scheme.toLowerCase();
	if (scheme == 'https') scheme = 'wss';
	if (scheme == 'http') scheme = 'ws';
	if (scheme != 'wss' && scheme != 'ws') {
		scheme = 'wss';
	}

	final port = uri.hasPort && uri.port > 0 ? uri.port : (scheme == 'wss' ? 443 : 80);
	final path = uri.path.isEmpty ? '/' : uri.path;

	return Uri(scheme: scheme, host: uri.host, port: port, path: path);
}
