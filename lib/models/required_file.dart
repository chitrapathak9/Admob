import 'package:xml/xml.dart';

import 'schedule_item.dart';

class RequiredFile {
	final String type;
	final String id;
	final int size;
	final String md5;
	final String saveAs;
	final String download;
	final String path;

	const RequiredFile({
		required this.type,
		required this.id,
		required this.size,
		required this.md5,
		required this.saveAs,
		this.download = 'xmds',
		this.path = '',
	});

	factory RequiredFile.empty() => const RequiredFile(
		type: '',
		id: '',
		size: 0,
		md5: '',
		saveAs: '',
		download: '',
		path: '',
	);

	bool get isEmpty => id.isEmpty && saveAs.isEmpty;

	bool get isXmdsDownload => download.toLowerCase() == 'xmds';

	bool get isHttpDownload => download.toLowerCase() == 'http';

	static final _imageExtensions = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};
	static final _videoExtensions = {'.mp4', '.webm', '.mov', '.mkv', '.m4v'};

	static bool isPlayableMediaFilename(String saveAs) {
		final lower = saveAs.toLowerCase();
		return _imageExtensions.any(lower.endsWith) || _videoExtensions.any(lower.endsWith);
	}

	static List<String> layoutIdsFromFiles(List<RequiredFile> files) {
		final ids = <String>[];
		for (final f in files) {
			if (f.saveAs.toLowerCase().endsWith('.xlf')) {
				final id = ScheduleItem.normalizeLayoutFileId(f.saveAs);
				if (!ScheduleItem.isDefaultFallbackLayout(id)) ids.add(id);
			} else if (f.type == 'layout' && f.id.isNotEmpty) {
				final id = ScheduleItem.normalizeLayoutFileId(f.id);
				if (!ScheduleItem.isDefaultFallbackLayout(id)) ids.add(id);
			}
		}
		return ids;
	}

	static RequiredFile? findBySaveAs(List<RequiredFile> files, String saveAs) {
		for (final f in files) {
			if (f.saveAs == saveAs) return f;
		}
		return null;
	}

	static List<RequiredFile> fromXmlDocument(XmlDocument doc) {
		final files = <RequiredFile>[];
		for (final element in doc.findAllElements('file')) {
			final saveAs = element.getAttribute('saveAs')?.trim() ?? '';
			final pathAttr = element.getAttribute('path')?.trim() ?? '';
			files.add(RequiredFile(
				type: element.getAttribute('type') ?? 'media',
				id: element.getAttribute('id') ?? '',
				size: int.tryParse(element.getAttribute('size') ?? '0') ?? 0,
				md5: element.getAttribute('md5') ?? '',
				saveAs: saveAs.isNotEmpty ? saveAs : pathAttr.split('/').last,
				download: element.getAttribute('download') ?? 'xmds',
				path: pathAttr,
			));
		}
		return files;
	}
}
