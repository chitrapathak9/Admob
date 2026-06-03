import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../config/app_config.dart';
import '../models/required_file.dart';
import '../models/schedule_item.dart';
import '../utils/app_logger.dart';
import '../utils/api_log_interceptor.dart';
import '../utils/device_name.dart';
import 'storage_service.dart';

class ScheduleResult {
	final List<ScheduleItem> schedule;
	final String defaultLayoutId;

	const ScheduleResult({required this.schedule, required this.defaultLayoutId});
}

class RegisterDisplayResult {
	final int code;
	final String message;

	const RegisterDisplayResult({required this.code, required this.message});
}

class XmdsService {
	XmdsService._();
	static final XmdsService instance = XmdsService._();

	final Dio _dio = Dio(BaseOptions(
		connectTimeout: const Duration(seconds: 60),
		receiveTimeout: const Duration(seconds: 120),
		headers: {
			'Content-Type': 'text/xml; charset=utf-8',
		},
	))..interceptors.add(ApiLogInterceptor());

	Future<String> _xmdsUrl() async {
		final url = await StorageService.instance.getXmdsUrl();
		if (url == null || url.isEmpty) {
			return '${AppConfig.baseUrl}/xmds.php';
		}
		return url;
	}

	Future<String> _serverKey() async {
		final key = await StorageService.instance.getCmsKey();
		if (key == null) throw Exception('CMS key not configured');
		return key;
	}

	Future<String> _hardwareKey() async {
		return StorageService.instance.getOrCreateHardwareKey();
	}

	String _envelope(String methodBody) => '''<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:tns="urn:xmds">
  <soap:Body>
    $methodBody
  </soap:Body>
</soap:Envelope>''';

	Future<String> _callRaw(String method, String methodBody) async {
		final url = await _xmdsUrl();
		final endpoint = '$url?v=${AppConfig.xmdsVersion}&method=$method';
		final envelope = _envelope(methodBody);

		AppLogger.xmds('→ POST $endpoint');
		AppLogger.xmds('  SOAP method=$method body: ${AppLogger.sanitizeBody(methodBody)}');

		final options = Options(
			headers: {'SOAPAction': 'urn:xmds#$method'},
			responseType: ResponseType.plain,
			validateStatus: (_) => true,
		);

		String body;
		int? httpStatus;
		try {
			final response = await _dio.post<String>(endpoint, data: envelope, options: options);
			httpStatus = response.statusCode;
			body = response.data ?? '';
		} on DioException catch (e, st) {
			httpStatus = e.response?.statusCode;
			body = e.response?.data?.toString() ?? '';
			AppLogger.apiError('XMDS', 'method=$method http=$httpStatus failed', e, st);
			if (body.isEmpty) {
				throw Exception('XMDS $method failed: ${e.message}');
			}
		}

		if (body.isEmpty) {
			AppLogger.apiError('XMDS', 'method=$method returned empty response');
			throw Exception('XMDS $method returned empty response');
		}

		if (httpStatus != null && httpStatus != 200) {
			final msg = _httpErrorMessage(method, httpStatus, body);
			AppLogger.apiError('XMDS', msg);
			throw Exception(msg);
		}

		if (_isNonXmlBody(body)) {
			final msg = 'XMDS $method returned non-XML body (HTTP ${httpStatus ?? "unknown"})';
			AppLogger.apiError('XMDS', msg);
			throw Exception(msg);
		}

		if (method == 'GetFile') {
			AppLogger.xmds('← HTTP $httpStatus method=$method response=${body.length} chars (base64 omitted)');
		} else {
			AppLogger.xmds('← HTTP $httpStatus method=$method response: ${AppLogger.truncate(body)}');
		}

		if (RegExp(r'<([^:>]+:)?Fault[\s>]', caseSensitive: false).hasMatch(body)) {
			final fault = _extractText(body, 'faultstring') ?? 'SOAP fault';
			AppLogger.apiError('XMDS', 'method=$method SOAP fault: $fault');
			throw Exception(fault);
		}

		AppLogger.xmds('OK method=$method');
		return body;
	}

	Future<XmlDocument> _call(String method, String methodBody) async {
		return _parseXml(await _callRaw(method, methodBody), context: method);
	}

	static bool _isNonXmlBody(String body) {
		final trimmed = body.trimLeft().toLowerCase();
		if (trimmed.startsWith('<!doctype') || trimmed.startsWith('<html')) return true;
		if (!trimmed.startsWith('<')) return true;
		return false;
	}

	static String _httpErrorMessage(String method, int status, String body) {
		if (_isNonXmlBody(body)) {
			return 'XMDS $method failed (HTTP $status): server returned HTML instead of SOAP XML';
		}
		return 'XMDS $method failed (HTTP $status)';
	}

	static XmlDocument _parseXml(String xml, {required String context}) {
		if (_isNonXmlBody(xml)) {
			throw Exception('$context: cannot parse non-XML response');
		}
		return XmlDocument.parse(xml);
	}

	String? _extractText(String xml, String tag) {
		if (_isNonXmlBody(xml)) return null;
		try {
			final doc = XmlDocument.parse(xml);
			final el = doc.findAllElements(tag).firstOrNull;
			return el?.innerText;
		} catch (_) {
			return null;
		}
	}

	/// Maps Xibo SOAP RegisterDisplay body to 200 (pending) / 201 (approved).
	RegisterDisplayResult _parseRegisterDisplayResponse(String body) {
		// theadbook/custom proxy: <code>200</code> | <code>201</code>
		final numericMatch = RegExp(r'<code>\s*(\d+)\s*</code>', caseSensitive: false).firstMatch(body);
		if (numericMatch != null) {
			return RegisterDisplayResult(
				code: int.tryParse(numericMatch.group(1)!) ?? 0,
				message: _extractTagText(body, 'message') ?? '',
			);
		}

		var xml = body;
		final activation = RegExp(
			r'<ActivationMessage[^>]*>([\s\S]*?)</ActivationMessage>',
			caseSensitive: false,
		).firstMatch(body);
		if (activation != null) {
			xml = _decodeEmbeddedXml(activation.group(1)!);
		}

		// Standard Xibo v5+: <display code="READY|WAITING|ADDED" message="..." />
		final displayMatch = RegExp(r'<display\b([^>]*)>', caseSensitive: false).firstMatch(xml);
		if (displayMatch != null) {
			final attrs = displayMatch.group(1)!;
			final displayCode = _readXmlAttribute(attrs, 'code')?.toUpperCase() ?? '';
			final message = _readXmlAttribute(attrs, 'message') ?? _extractTagText(xml, 'message') ?? '';

			if (displayCode == 'READY' || _isReadyMessage(message)) {
				return RegisterDisplayResult(code: 201, message: message);
			}
			if (displayCode == 'WAITING' || displayCode == 'ADDED') {
				return RegisterDisplayResult(code: 200, message: message);
			}
		}

		// XMDS v3 plain-text response
		if (_isReadyMessage(body)) {
			return const RegisterDisplayResult(
				code: 201,
				message: 'Display is active and ready to start.',
			);
		}
		if (body.toLowerCase().contains('awaiting')) {
			return RegisterDisplayResult(code: 200, message: body);
		}

		// Fallback attribute scan
		if (RegExp(r'''code\s*=\s*["']READY["']''', caseSensitive: false).hasMatch(body)) {
			return RegisterDisplayResult(code: 201, message: _extractTagText(body, 'message') ?? 'READY');
		}

		return RegisterDisplayResult(code: 200, message: _extractTagText(body, 'message') ?? '');
	}

	bool _isReadyMessage(String text) =>
		text.toLowerCase().contains('active and ready to start');

	String _decodeEmbeddedXml(String fragment) {
		var s = fragment.trim();
		if (s.startsWith('<![CDATA[')) {
			s = s.substring(9);
			if (s.endsWith(']]>')) s = s.substring(0, s.length - 3);
		}
		return unescapeXml(s);
	}

	/// Unescapes HTML entities in double-encoded XMDS payload strings.
	String unescapeXml(String input) {
		return input
			.replaceAll('&lt;', '<')
			.replaceAll('&gt;', '>')
			.replaceAll('&amp;', '&')
			.replaceAll('&quot;', '"')
			.replaceAll('&#39;', "'");
	}

	/// Extracts and unescapes inner payload from a SOAP XMDS response.
	String extractUnescapedSoapInner(String rawSoap, {required List<String> wrapperNames}) {
		final envelope = _parseXml(rawSoap, context: 'SOAP envelope');

		String? innerContent;
		for (final wrapperName in wrapperNames) {
			for (final el in envelope.findAllElements(wrapperName)) {
				final text = el.innerText.trim();
				if (text.isNotEmpty) {
					innerContent = text;
					break;
				}
			}
			if (innerContent != null) break;
		}

		if (innerContent == null) {
			final wanted = wrapperNames.map((n) => n.toLowerCase()).toSet();
			for (final el in envelope.descendants.whereType<XmlElement>()) {
				if (wanted.contains(el.name.local.toLowerCase())) {
					final text = el.innerText.trim();
					if (text.isNotEmpty) {
						innerContent = text;
						break;
					}
				}
			}
		}

		return unescapeXml(innerContent ?? rawSoap);
	}

	XmlDocument _parseSoapInnerDocument(String rawSoap, {required List<String> wrapperNames}) {
		return _parseXml(
			extractUnescapedSoapInner(rawSoap, wrapperNames: wrapperNames),
			context: 'SOAP inner',
		);
	}

	String? _readXmlAttribute(String attrs, String name) {
		final m = RegExp('$name\\s*=\\s*["\']([^"\']*)["\']', caseSensitive: false).firstMatch(attrs);
		return m?.group(1)?.trim();
	}

	String? _extractTagText(String xml, String tag) {
		final m = RegExp('<$tag[^>]*>([\\s\\S]*?)</$tag>', caseSensitive: false).firstMatch(xml);
		return m?.group(1)?.trim();
	}

	Future<RegisterDisplayResult> registerDisplay(String displayName) async {
		AppLogger.register('registerDisplay displayName="$displayName"');

		final body = '''<tns:RegisterDisplay>
      <serverKey>${await _serverKey()}</serverKey>
      <hardwareKey>${await _hardwareKey()}</hardwareKey>
      <displayName>${_escapeXml(displayName)}</displayName>
      <clientType>${AppConfig.clientType}</clientType>
      <clientVersion>${AppConfig.clientVersion}</clientVersion>
      <clientCode>${AppConfig.clientCode}</clientCode>
      <operatingSystem>${registerOperatingSystem()}</operatingSystem>
      <macAddress></macAddress>
    </tns:RegisterDisplay>''';

		try {
			final raw = await _callRaw('RegisterDisplay', body);
			final result = _parseRegisterDisplayResponse(raw);
			AppLogger.register('OK code=${result.code} message="${result.message}"');
			return result;
		} catch (e, st) {
			AppLogger.registerError('registerDisplay failed', e, st);
			rethrow;
		}
	}

	Future<List<RequiredFile>> getRequiredFiles() async {
		AppLogger.xmds('getRequiredFiles');

		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final body = '''<tns:RequiredFiles>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
    </tns:RequiredFiles>''';

		final raw = await _callRaw('RequiredFiles', body);
		final doc = _parseSoapInnerDocument(
			raw,
			wrapperNames: ['RequiredFilesXml', 'requiredFilesXml', 'RequiredFiles'],
		);
		final files = RequiredFile.fromXmlDocument(doc);
		final byType = <String, int>{};
		for (final f in files) {
			byType[f.type] = (byType[f.type] ?? 0) + 1;
		}
		AppLogger.xmds('getRequiredFiles OK count=${files.length} byType=$byType');
		return files;
	}

	/// Decodes base64 payload from GetFile SOAP response.
	Uint8List decodeGetFileResponse(String rawSoap, {bool log = false}) {
		final doc = _parseXml(rawSoap, context: 'GetFile');
		final fileEl = doc.findAllElements('file').firstOrNull;
		if (fileEl == null) {
			throw Exception('GetFile response missing <file> element');
		}

		var base64String = fileEl.innerText.trim().replaceAll(RegExp(r'\s+'), '');
		if (log) {
			AppLogger.download('GetFile base64 length: ${base64String.length}');
			if (base64String.isEmpty) {
				AppLogger.apiError('Download', 'empty base64 in GetFile response');
			}
		}
		if (base64String.isEmpty) {
			return Uint8List(0);
		}

		return Uint8List.fromList(base64Decode(base64String));
	}

	Future<Uint8List> getFileChunk({
		required String fileId,
		required String fileType,
		required int chunkOffset,
		required int chunkSize,
		bool logResponse = false,
	}) async {
		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		AppLogger.xmds('getFileChunk fileId=$fileId type=$fileType offset=$chunkOffset size=$chunkSize');

		final body = '''<tns:GetFile>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
      <fileId>$fileId</fileId>
      <fileType>$fileType</fileType>
      <chunkOffset>$chunkOffset</chunkOffset>
      <chunkSize>$chunkSize</chunkSize>
    </tns:GetFile>''';

		final raw = await _callRaw('GetFile', body);
		final bytes = decodeGetFileResponse(raw, log: logResponse);
		AppLogger.xmds('getFileChunk OK fileId=$fileId bytes=${bytes.length}');
		return bytes;
	}

	Future<List<ScheduleItem>> getSchedule() async {
		return (await getScheduleWithDefault()).schedule;
	}

	Future<ScheduleResult> getScheduleWithDefault() async {
		AppLogger.xmds('getSchedule');

		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final body = '''<tns:Schedule>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
    </tns:Schedule>''';

		final raw = await _callRaw('Schedule', body);
		const wrappers = ['ScheduleXml', 'scheduledXml', 'Schedule'];
		final unescapedSchedule = extractUnescapedSoapInner(raw, wrapperNames: wrappers);

		final doc = _parseXml(unescapedSchedule, context: 'Schedule');
		final schedule = ScheduleItem.fromXmlDocument(doc);
		final layoutFileIds = ScheduleItem.layoutFileIdsFromDocument(doc);
		final defaultLayoutId = ScheduleItem.parseDefaultLayoutId(doc);
		AppLogger.xmds(
			'getSchedule OK items=${schedule.length} layouts=$layoutFileIds defaultLayout=$defaultLayoutId',
		);
		return ScheduleResult(
			schedule: schedule,
			defaultLayoutId: defaultLayoutId,
		);
	}

	Future<void> submitStats({
		required String statXml,
	}) async {
		AppLogger.xmds('submitStats statXml=${AppLogger.truncate(statXml, max: 200)}');

		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final body = '''<tns:SubmitStats>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
      <statXml>${_escapeXml(statXml)}</statXml>
    </tns:SubmitStats>''';

		await _call('SubmitStats', body);
		AppLogger.xmds('submitStats OK');
	}

	Future<void> mediaInventory(List<RequiredFile> files) async {
		AppLogger.xmds('mediaInventory fileCount=${files.length}');

		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final fileNodes = files
			.map((f) => '<file id="${f.id}" md5="${f.md5}" complete="1" />')
			.join('\n        ');

		final body = '''<tns:MediaInventory>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
      <mediaInventory>
        $fileNodes
      </mediaInventory>
    </tns:MediaInventory>''';

		await _call('MediaInventory', body);
		AppLogger.xmds('mediaInventory OK');
	}

	Future<void> notifyStatus({
		required String layoutId,
		required int freeMB,
		String lastMediaId = '0',
	}) async {
		AppLogger.xmds('notifyStatus layoutId=$layoutId freeMB=$freeMB lastMediaId=$lastMediaId');

		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final body = '''<tns:NotifyStatus>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
      <status>
        <current_layout>$layoutId</current_layout>
        <available_space>$freeMB</available_space>
        <last_viewed_id>$lastMediaId</last_viewed_id>
      </status>
    </tns:NotifyStatus>''';

		await _call('NotifyStatus', body);
		AppLogger.xmds('notifyStatus OK');
	}

	String _escapeXml(String input) => input
		.replaceAll('&', '&amp;')
		.replaceAll('<', '&lt;')
		.replaceAll('>', '&gt;')
		.replaceAll('"', '&quot;');
}

extension _XmlFirstOrNull on Iterable<XmlElement> {
	XmlElement? get firstOrNull {
		final it = iterator;
		if (!it.moveNext()) return null;
		return it.current;
	}
}
