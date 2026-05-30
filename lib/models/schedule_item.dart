import 'package:xml/xml.dart';

class ScheduleItem {
	final String layoutFile;
	final int duration;
	final int priority;
	final int scheduleId;
	final String fromDt;
	final String toDt;

	const ScheduleItem({
		required this.layoutFile,
		required this.duration,
		required this.priority,
		required this.scheduleId,
		required this.fromDt,
		required this.toDt,
	});

	/// Layout id from schedule `file` attribute (e.g. "32" → XLF is "32.xlf").
	String get layoutId => ScheduleItem.normalizeLayoutFileId(layoutFile);

	String get xlfFilename {
		final id = layoutId;
		return id.endsWith('.xlf') ? id : '$id.xlf';
	}

	/// Xibo CMS default fallback layout — not in RequiredFiles, not GetFile-able.
	static const String defaultFallbackLayoutId = '1';

	static String normalizeLayoutFileId(String raw) {
		var id = raw.trim();
		if (id.endsWith('.xlf')) {
			id = id.substring(0, id.length - 4);
		}
		return id;
	}

	static bool isDefaultFallbackLayout(String raw) {
		return normalizeLayoutFileId(raw) == defaultFallbackLayoutId;
	}

	/// Scheduled layouts excluding Xibo's non-downloadable default layout 1.
	static List<ScheduleItem> withoutDefaultFallback(List<ScheduleItem> items) {
		return items.where((item) => !isDefaultFallbackLayout(item.layoutId)).toList();
	}

	/// Layouts whose fromdt/todt window includes now (empty dates = always active).
	static List<ScheduleItem> filterActiveNow(List<ScheduleItem> items) {
		return items.where((item) => _isActiveNow(item.fromDt, item.toDt)).toList();
	}

	static bool _isActiveNow(String fromDt, String toDt) {
		final now = DateTime.now();
		final from = _parseScheduleDate(fromDt);
		final to = _parseScheduleDate(toDt);
		if (from != null && now.isBefore(from)) return false;
		if (to != null && now.isAfter(to)) return false;
		return true;
	}

	static DateTime? _parseScheduleDate(String raw) {
		final s = raw.trim();
		if (s.isEmpty) return null;
		final normalized = s.contains('T') ? s : s.replaceFirst(' ', 'T');
		return DateTime.tryParse(normalized);
	}

	static String? _attr(XmlElement el, String name) {
		return el.getAttribute(name) ??
			el.getAttribute(name.toLowerCase()) ??
			el.getAttribute(name.toUpperCase());
	}

	/// Placeholder items when layouts exist in RequiredFiles but not in Schedule XML.
	static List<ScheduleItem> fromLayoutIds(Iterable<String> layoutIds) {
		return layoutIds
			.where((id) => id.isNotEmpty && !isDefaultFallbackLayout(id))
			.map(
				(id) => ScheduleItem(
					layoutFile: id,
					duration: 10,
					priority: 0,
					scheduleId: 0,
					fromDt: '',
					toDt: '',
				),
			)
			.toList();
	}

	static List<String> layoutFileIdsFromDocument(XmlDocument doc) {
		final ids = <String>[];
		for (final layout in doc.findAllElements('layout')) {
			final file = layout.getAttribute('file')?.trim() ?? '';
			if (file.isNotEmpty) {
				ids.add(normalizeLayoutFileId(file));
			}
		}
		return ids;
	}

	static List<ScheduleItem> fromXmlDocument(XmlDocument doc) {
		final items = <ScheduleItem>[];
		for (final layout in doc.findAllElements('layout')) {
			final file = _attr(layout, 'file')?.trim() ?? '';
			if (file.isEmpty) continue;
			items.add(ScheduleItem(
				layoutFile: normalizeLayoutFileId(file),
				duration: int.tryParse(_attr(layout, 'duration') ?? '0') ?? 0,
				priority: int.tryParse(_attr(layout, 'priority') ?? '0') ?? 0,
				scheduleId: int.tryParse(_attr(layout, 'scheduleid') ?? '0') ?? 0,
				fromDt: _attr(layout, 'fromdt') ?? '',
				toDt: _attr(layout, 'todt') ?? '',
			));
		}
		return items;
	}

	static String parseDefaultLayoutId(XmlDocument doc) {
		final defaultEl = doc.findAllElements('default').firstOrNull;
		if (defaultEl != null) {
			final fileAttr = defaultEl.getAttribute('file')?.trim();
			if (fileAttr != null && fileAttr.isNotEmpty) {
				return normalizeLayoutFileId(fileAttr);
			}
			final layoutId = defaultEl.getAttribute('layoutid')?.trim();
			if (layoutId != null && layoutId.isNotEmpty) {
				return normalizeLayoutFileId(layoutId);
			}
		}

		final el = doc.findAllElements('defaultLayout').firstOrNull;
		final text = el?.innerText.trim() ?? '';
		if (text.isNotEmpty) return normalizeLayoutFileId(text);
		return '';
	}
}

extension _XmlFirstOrNull on Iterable<XmlElement> {
	XmlElement? get firstOrNull {
		final it = iterator;
		if (!it.moveNext()) return null;
		return it.current;
	}
}
