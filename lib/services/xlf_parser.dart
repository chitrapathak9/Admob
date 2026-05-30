import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

import '../models/download_progress.dart';
import '../models/play_item.dart';
import '../models/required_file.dart';
import '../models/schedule_item.dart';
import 'download_service.dart';

class PlaylistBuildResult {
	final List<PlayItem> playlist;
	final String layoutId;
	final int mediaReady;
	final int mediaTotal;
	final DownloadProgress downloadProgress;

	const PlaylistBuildResult({
		required this.playlist,
		required this.layoutId,
		required this.mediaReady,
		required this.mediaTotal,
		this.downloadProgress = const DownloadProgress(),
	});
}

class XlfParser {
	XlfParser._();
	static final XlfParser instance = XlfParser._();

	/// Parses every scheduled layout XLF and merges media into one playlist.
	Future<PlaylistBuildResult> buildPlaylistFromSchedule({
		required List<ScheduleItem> schedule,
		required String defaultLayoutId,
		required List<RequiredFile> requiredFiles,
	}) async {
		final layoutIds = <String>[];
		final scheduleByLayout = <String, ScheduleItem>{};

		var scheduled = ScheduleItem.filterActiveNow(ScheduleItem.withoutDefaultFallback(schedule));
		if (scheduled.isEmpty) {
			final fromRequired = RequiredFile.layoutIdsFromFiles(requiredFiles);
			if (fromRequired.isNotEmpty) {
				scheduled = ScheduleItem.fromLayoutIds(fromRequired);
				debugPrint('[XLF] Using layout IDs from RequiredFiles: $fromRequired');
			}
		}
		if (scheduled.isNotEmpty) {
			final sorted = List<ScheduleItem>.from(scheduled)
				..sort((a, b) => b.priority.compareTo(a.priority));
			for (final item in sorted) {
				if (item.layoutId.isEmpty || layoutIds.contains(item.layoutId)) continue;
				layoutIds.add(item.layoutId);
				scheduleByLayout[item.layoutId] = item;
			}
		} else {
			final normalized = ScheduleItem.normalizeLayoutFileId(defaultLayoutId);
			if (normalized.isNotEmpty && !ScheduleItem.isDefaultFallbackLayout(normalized)) {
				layoutIds.add(normalized);
			}
		}

		if (layoutIds.isEmpty) {
			debugPrint('[XLF] No layout ids from schedule or default');
			final progress = await DownloadService.instance.computeDownloadProgress(requiredFiles);
			return PlaylistBuildResult(
				playlist: [],
				layoutId: '',
				mediaReady: progress.filesReady,
				mediaTotal: progress.filesTotal,
				downloadProgress: progress,
			);
		}

		debugPrint('[XLF] Layout file IDs to parse: $layoutIds');

		final playlist = <PlayItem>[];
		final primaryLayoutId = layoutIds.first;

		for (final layoutId in layoutIds) {
			debugPrint('[XLF] Parsing layout: $layoutId');

			final xlfPath = await _resolveXlfLocalPath(layoutId, requiredFiles);
			debugPrint('[XLF] Looking for local file: $xlfPath');
			final xlfExists = await File(xlfPath).exists();
			debugPrint('[XLF] File exists: $xlfExists');

			final scheduleId = scheduleByLayout[layoutId]?.scheduleId ?? 0;
			List<PlayItem> layoutItems;

			if (xlfExists) {
				layoutItems = await parse(
					xlfPath,
					layoutId: layoutId,
					scheduleId: scheduleId,
					requiredFiles: requiredFiles,
				);
			} else {
				debugPrint('[XLF] XLF missing: $xlfPath — trying native playlist from RequiredFiles');
				layoutItems = await _buildNativePlaylistFromRequired(
					layoutId: layoutId,
					scheduleId: scheduleId,
					requiredFiles: requiredFiles,
				);
			}

			playlist.addAll(layoutItems);
			debugPrint('[XLF] Items from layout $layoutId: ${layoutItems.length}');
		}

		final progress = await DownloadService.instance.computeDownloadProgress(requiredFiles);

		if (playlist.isEmpty) {
			debugPrint('[XLF] XLF playlist empty — fallback from RequiredFiles media on disk');
			playlist.addAll(await _buildFallbackPlaylistFromRequired(requiredFiles: requiredFiles));
		}

		debugPrint('[XLF] Total playlist items: ${playlist.length}');
		return PlaylistBuildResult(
			playlist: playlist,
			layoutId: primaryLayoutId,
			mediaReady: progress.filesReady,
			mediaTotal: progress.filesTotal,
			downloadProgress: progress,
		);
	}

	Future<String> _resolveXlfLocalPath(String layoutId, List<RequiredFile> requiredFiles) async {
		final layoutRequired = requiredFiles.where(
			(f) => f.type == 'layout' && f.id == layoutId,
		);
		for (final f in layoutRequired) {
			if (f.saveAs.isNotEmpty) {
				return DownloadService.instance.getLocalPath(f.saveAs);
			}
		}
		return DownloadService.instance.getLocalPath('$layoutId.xlf');
	}

	Future<List<PlayItem>> parse(
		String xlfFilePath, {
		String layoutId = '',
		int scheduleId = 0,
		List<RequiredFile> requiredFiles = const [],
	}) async {
		final file = File(xlfFilePath);
		if (!await file.exists()) {
			debugPrint('[XLF] XLF file missing: $xlfFilePath');
			return [];
		}

		final content = await file.readAsString();
		final previewEnd = content.length > 300 ? 300 : content.length;
		debugPrint('[XLF] File content first 300 chars: ${content.substring(0, previewEnd)}');

		final doc = XmlDocument.parse(content);
		final mediaElements = doc.findAllElements('media').toList();
		debugPrint('[XLF] Media elements in layout $layoutId: ${mediaElements.length}');

		final items = <PlayItem>[];
		final appDir = await DownloadService.instance.getAppStorageDir();

		for (final media in mediaElements) {
			final rawType = (media.getAttribute('type') ?? '').toLowerCase();
			final mediaId = media.getAttribute('id') ?? media.getAttribute('file') ?? '';
			final uriPreview = _resolveMediaFilename(media, requiredFiles, mediaId) ?? '';

			if (!_isPlayableMedia(rawType, uriPreview)) {
				debugPrint('[XLF] Skipping non-playable type: $rawType uri=$uriPreview');
				continue;
			}

			final type = _playbackType(rawType, uriPreview);
			final duration = int.tryParse(media.getAttribute('duration') ?? '10') ?? 10;

			final uri = uriPreview.isNotEmpty
				? uriPreview
				: _resolveMediaFilename(media, requiredFiles, mediaId);
			if (uri == null || uri.isEmpty) {
				debugPrint('[XLF] No URI found in media element — skipping');
				continue;
			}

			final localPath = '${appDir.path}/$uri';
			final exists = await File(localPath).exists();
			debugPrint('[XLF] Layout $layoutId → $uri exists=$exists');
			if (!exists) {
				debugPrint('[XLF] File missing locally: $uri — skipping');
				continue;
			}

			debugPrint('[XLF] Added to playlist: $uri');

			items.add(PlayItem(
				localPath: localPath,
				type: type,
				duration: duration,
				mediaId: mediaId,
				layoutId: layoutId,
				scheduleId: scheduleId,
			));
		}

		return items;
	}

	String? _resolveMediaFilename(
		XmlElement media,
		List<RequiredFile> requiredFiles,
		String mediaId,
	) {
		final uriEl = media.findAllElements('uri').firstOrNull;
		var uri = uriEl?.innerText.trim() ?? '';

		if (uri.isEmpty) {
			final fileAttr = media.getAttribute('file')?.trim() ?? '';
			if (fileAttr.isNotEmpty) {
				final match = requiredFiles.where(
					(f) => f.type == 'media' && f.id == fileAttr,
				);
				for (final f in match) {
					if (f.saveAs.isNotEmpty) return f.saveAs;
				}
				uri = fileAttr;
			}
		} else {
			final match = requiredFiles.where(
				(f) => f.type == 'media' && (f.saveAs == uri || f.id == mediaId),
			);
			for (final f in match) {
				if (f.saveAs.isNotEmpty) return f.saveAs;
			}
		}

		return uri.isEmpty ? null : uri;
	}

	bool _isPlayableMedia(String rawType, String uri) {
		final t = rawType.toLowerCase();
		if (t.contains('video')) return true;
		if (t.contains('image') || t == 'img' || t == 'picture') return true;
		if (uri.isNotEmpty && RequiredFile.isPlayableMediaFilename(uri)) return true;
		return false;
	}

	String _playbackType(String rawType, String uri) {
		final t = rawType.toLowerCase();
		if (t.contains('video')) return 'video';
		if (uri.toLowerCase().endsWith('.mp4') ||
			uri.toLowerCase().endsWith('.webm') ||
			uri.toLowerCase().endsWith('.mov') ||
			uri.toLowerCase().endsWith('.mkv')) {
			return 'video';
		}
		return 'image';
	}

	/// Builds playlist from downloaded image/video files when XLF parsing yields nothing.
	Future<List<PlayItem>> _buildFallbackPlaylistFromRequired({
		required List<RequiredFile> requiredFiles,
	}) async {
		final appDir = await DownloadService.instance.getAppStorageDir();
		final items = <PlayItem>[];

		for (final f in requiredFiles) {
			if (DownloadService.shouldSkipPlaybackFile(f)) continue;
			if (!RequiredFile.isPlayableMediaFilename(f.saveAs)) continue;

			final localPath = '${appDir.path}/${f.saveAs}';
			if (!await File(localPath).exists()) continue;

			final lower = f.saveAs.toLowerCase();
			final type = lower.endsWith('.mp4') ||
					lower.endsWith('.webm') ||
					lower.endsWith('.mov') ||
					lower.endsWith('.mkv')
				? 'video'
				: 'image';

			debugPrint('[XLF] Fallback playlist: ${f.saveAs}');
			items.add(PlayItem(
				localPath: localPath,
				type: type,
				duration: 10,
				mediaId: f.id,
			));
		}
		return items;
	}

	/// When CMS omits layout XLF, play XMDS media files that are on disk (positive media ids).
	Future<List<PlayItem>> _buildNativePlaylistFromRequired({
		required String layoutId,
		required int scheduleId,
		required List<RequiredFile> requiredFiles,
	}) async {
		final appDir = await DownloadService.instance.getAppStorageDir();
		final items = <PlayItem>[];

		for (final f in requiredFiles) {
			if (f.type != 'media' || !f.isXmdsDownload) continue;
			final mediaId = int.tryParse(f.id);
			if (mediaId == null || mediaId <= 0) continue;

			final saveAs = f.saveAs.isNotEmpty ? f.saveAs : f.id;
			final localPath = '${appDir.path}/$saveAs';
			if (!await File(localPath).exists()) continue;

			final ext = saveAs.toLowerCase();
			final type = ext.endsWith('.mp4') ||
					ext.endsWith('.webm') ||
					ext.endsWith('.mov') ||
					ext.endsWith('.mkv')
				? 'video'
				: 'image';

			debugPrint('[XLF] Native playlist item: $saveAs (id=$mediaId)');
			items.add(PlayItem(
				localPath: localPath,
				type: type,
				duration: 10,
				mediaId: f.id,
				layoutId: layoutId,
				scheduleId: scheduleId,
			));
		}

		return items;
	}
}

extension _XmlFirstOrNull on Iterable<XmlElement> {
	XmlElement? get firstOrNull {
		final it = iterator;
		if (!it.moveNext()) return null;
		return it.current;
	}
}
