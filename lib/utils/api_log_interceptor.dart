import 'package:dio/dio.dart';

import 'app_logger.dart';

/// Logs every Dio HTTP request/response. Tag is derived from the URL path.
class ApiLogInterceptor extends Interceptor {
	ApiLogInterceptor({this.logResponseBody = true});

	final bool logResponseBody;

	static String tagFor(RequestOptions options) {
		final path = options.path;
		final uri = options.uri.toString();
		if (path.contains('/screens/connect')) return 'Connect';
		if (path.contains('/screens/status')) return 'Status';
		if (path.contains('/player/manifest')) return 'Manifest';
		if (path.contains('/player/heartbeat')) return 'Heartbeat';
		if (path.contains('/player/offline')) return 'Offline';
		if (path.contains('/player/config')) return 'Config';
		if (path.contains('/player/health')) return 'Health';
		if (uri.contains('xmds.php')) return 'XMDS';
		if (options.responseType == ResponseType.bytes) return 'Download';
		return 'HTTP';
	}

	@override
	void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
		final tag = tagFor(options);
		AppLogger.api(tag, '→ ${options.method} ${options.uri}');
		if (options.data != null) {
			AppLogger.api(tag, '  request: ${AppLogger.sanitizeBody(options.data)}');
		}
		if (options.queryParameters.isNotEmpty) {
			AppLogger.api(tag, '  query: ${options.queryParameters}');
		}
		handler.next(options);
	}

	@override
	void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
		final tag = tagFor(response.requestOptions);
		AppLogger.api(
			tag,
			'← HTTP ${response.statusCode} ${response.requestOptions.method} ${response.requestOptions.uri}',
		);
		if (logResponseBody) {
			AppLogger.api(tag, '  response: ${_formatBody(response.data, response.requestOptions)}');
		}
		handler.next(response);
	}

	@override
	void onError(DioException err, ErrorInterceptorHandler handler) {
		final tag = tagFor(err.requestOptions);
		AppLogger.apiError(
			tag,
			'← FAILED ${err.requestOptions.method} ${err.requestOptions.uri} '
			'http=${err.response?.statusCode} type=${err.type} message=${err.message}',
			err,
			err.stackTrace,
		);
		if (err.response?.data != null) {
			AppLogger.api(tag, '  error body: ${_formatBody(err.response!.data, err.requestOptions)}');
		}
		handler.next(err);
	}

	String _formatBody(dynamic data, RequestOptions options) {
		if (data == null) return '(empty)';
		if (data is List) return '<binary ${data.length} bytes>';
		if (data is String) {
			if (options.uri.toString().contains('xmds.php') && data.contains('<file>')) {
				return '<SOAP GetFile ${data.length} chars — base64 omitted>';
			}
			if (data.length > 2000 && options.uri.toString().contains('method=GetFile')) {
				return '<SOAP response ${data.length} chars — truncated>';
			}
		}
		return AppLogger.sanitizeBody(data);
	}
}
