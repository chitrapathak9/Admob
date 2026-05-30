import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../config/app_config.dart';
import '../models/required_file.dart';
import '../models/schedule_item.dart';
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
	));

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

		// Xibo returns SOAP faults with HTTP 500 — read body instead of throwing.
		final options = Options(
			headers: {'SOAPAction': 'urn:xmds#$method'},
			responseType: ResponseType.plain,
			validateStatus: (_) => true,
		);

		String body;
		try {
			final response = await _dio.post<String>(endpoint, data: envelope, options: options);
			body = response.data ?? '';
		} on DioException catch (e) {
			body = e.response?.data?.toString() ?? '';
			if (body.isEmpty) {
				throw Exception('XMDS $method failed: ${e.message}');
			}
		}

		if (body.isEmpty) {
			throw Exception('XMDS $method returned empty response');
		}
		if (RegExp(r'<([^:>]+:)?Fault[\s>]', caseSensitive: false).hasMatch(body)) {
			final fault = _extractText(body, 'faultstring') ?? 'SOAP fault';
			throw Exception(fault);
		}
		return body;
	}

	Future<XmlDocument> _call(String method, String methodBody) async {
		return XmlDocument.parse(await _callRaw(method, methodBody));
	}

	String? _extractText(String xml, String tag) {
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
		final envelope = XmlDocument.parse(rawSoap);

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
		return XmlDocument.parse(extractUnescapedSoapInner(rawSoap, wrapperNames: wrapperNames));
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
		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final body = '''<tns:RegisterDisplay>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
      <displayName>${_escapeXml(displayName)}</displayName>
      <clientType>${AppConfig.clientType}</clientType>
      <clientVersion>${AppConfig.clientVersion}</clientVersion>
      <clientCode>${AppConfig.clientCode}</clientCode>
      <operatingSystem>${registerOperatingSystem()}</operatingSystem>
      <macAddress></macAddress>
    </tns:RegisterDisplay>''';

		final raw = await _callRaw('RegisterDisplay', body);
		return _parseRegisterDisplayResponse(raw);
	}

	Future<List<RequiredFile>> getRequiredFiles() async {
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
		final unescapedPreview = doc.toXmlString(pretty: false);
		final rfEnd = unescapedPreview.length > 200 ? 200 : unescapedPreview.length;
		debugPrint('[XMDS] Unescaped requiredFiles XML: ${unescapedPreview.substring(0, rfEnd)}');
		debugPrint('[XMDS] Required files count: ${files.length}');
		final byType = <String, int>{};
		for (final f in files) {
			byType[f.type] = (byType[f.type] ?? 0) + 1;
		}
		debugPrint('[XMDS] Required files by type: $byType');
		for (final f in files.where((f) => f.type == 'layout' || f.saveAs.endsWith('.xlf'))) {
			debugPrint('[XMDS] Layout entry: id=${f.id} saveAs=${f.saveAs} download=${f.download}');
		}
		return files;
	}

	/// Decodes base64 payload from GetFile SOAP response.
	Uint8List decodeGetFileResponse(String rawSoap, {bool log = false}) {
		final doc = XmlDocument.parse(rawSoap);
		final fileEl = doc.findAllElements('file').firstOrNull;
		if (fileEl == null) {
			throw Exception('GetFile response missing <file> element');
		}

		var base64String = fileEl.innerText.trim().replaceAll(RegExp(r'\s+'), '');
		if (log) {
			debugPrint('[Download] Base64 length: ${base64String.length}');
			if (base64String.isEmpty) {
				debugPrint('[Download] ERROR: empty base64 in GetFile response');
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

		final body = '''<tns:GetFile>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
      <fileId>$fileId</fileId>
      <fileType>$fileType</fileType>
      <chunkOffset>$chunkOffset</chunkOffset>
      <chunkSize>$chunkSize</chunkSize>
    </tns:GetFile>''';

		final raw = await _callRaw('GetFile', body);
		if (logResponse) {
			final end = raw.length > 300 ? 300 : raw.length;
			debugPrint('[Download] GetFile raw response (first 300): ${raw.substring(0, end)}');
		}

		final bytes = decodeGetFileResponse(raw, log: logResponse);
		if (logResponse) {
			debugPrint('[Download] Base64 decoded bytes: ${bytes.length}');
		}
		return bytes;
	}

	Future<List<ScheduleItem>> getSchedule() async {
		return (await getScheduleWithDefault()).schedule;
	}

	Future<ScheduleResult> getScheduleWithDefault() async {
		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final body = '''<tns:Schedule>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
    </tns:Schedule>''';

		final raw = await _callRaw('Schedule', body);
		const wrappers = ['ScheduleXml', 'scheduledXml', 'Schedule'];
		final unescapedSchedule = extractUnescapedSoapInner(raw, wrapperNames: wrappers);
		debugPrint('[XLF] Unescaped schedule: $unescapedSchedule');

		final doc = XmlDocument.parse(unescapedSchedule);
		final schedule = ScheduleItem.fromXmlDocument(doc);
		final layoutFileIds = ScheduleItem.layoutFileIdsFromDocument(doc);
		debugPrint('[XLF] Layout file IDs from schedule: $layoutFileIds');
		debugPrint('[XMDS] Layout count after fix: ${layoutFileIds.length}');
		return ScheduleResult(
			schedule: schedule,
			defaultLayoutId: ScheduleItem.parseDefaultLayoutId(doc),
		);
	}

	Future<void> submitStats({
		required String statXml,
	}) async {
		final serverKey = await _serverKey();
		final hardwareKey = await _hardwareKey();

		final body = '''<tns:SubmitStats>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
      <statXml>${_escapeXml(statXml)}</statXml>
    </tns:SubmitStats>''';

		await _call('SubmitStats', body);
	}

	Future<void> mediaInventory(List<RequiredFile> files) async {
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
	}

	Future<void> notifyStatus({
		required String layoutId,
		required int freeMB,
		String lastMediaId = '0',
	}) async {
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
