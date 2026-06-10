/// Normalizes WebSocket URLs for [WebSocketChannel.connect].
///
/// Fixes common backend issues: https→wss, trailing `#`, missing port, empty path.
Uri normalizeWebSocketUri(String url) {
	var trimmed = url.trim();
	if (trimmed.isEmpty) {
		throw ArgumentError('Empty WebSocket URL');
	}

	// Strip fragment (#...) and trailing hash junk from malformed URLs.
	final hashIndex = trimmed.indexOf('#');
	if (hashIndex >= 0) {
		trimmed = trimmed.substring(0, hashIndex).trim();
	}
	while (trimmed.endsWith('#') || trimmed.endsWith('/')) {
		trimmed = trimmed.substring(0, trimmed.length - 1).trim();
	}

	var uri = Uri.tryParse(trimmed);
	if (uri == null || uri.host.isEmpty) {
		// e.g. "xibo-be.yourpreview.space/xmr"
		uri = Uri.tryParse('wss://$trimmed');
	}
	if (uri == null || uri.host.isEmpty) {
		throw ArgumentError('Invalid WebSocket URL: $url');
	}

	var scheme = uri.scheme.toLowerCase();
	if (scheme.isEmpty || scheme == 'https') scheme = 'wss';
	if (scheme == 'http') scheme = 'ws';
	if (scheme != 'wss' && scheme != 'ws') scheme = 'wss';

	final port = uri.hasPort && uri.port > 0 ? uri.port : (scheme == 'wss' ? 443 : 80);
	var path = uri.path;
	if (path.isEmpty) path = '/';

	return Uri(scheme: scheme, host: uri.host, port: port, path: path);
}
