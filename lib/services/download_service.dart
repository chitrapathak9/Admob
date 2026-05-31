import 'dart:io';
import 'dart:math' show min;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../core/logger.dart';
import '../models/download_progress.dart';
import '../models/required_file.dart';
import '../models/schedule_item.dart';
import 'xmds_service.dart';

class DownloadService {
	DownloadService._();
	static final DownloadService instance = DownloadService._();

	static const _skipExtensions = {'otf', 'ttf', 'woff', 'woff2', 'js', 'css'};

	final Dio _http = Dio(BaseOptions(
		connectTimeout: const Duration(seconds: 60),
		receiveTimeout: const Duration(seconds: 60),
		responseType: ResponseType.bytes,
	));

	Directory? _appDir;

	Future<Directory> getAppStorageDir() async {
		_appDir ??= await getApplicationDocumentsDirectory();
		return _appDir!;
	}

	Future<String> getLocalPath(String saveAs) async {
		final dir = await getAppStorageDir();
		return '${dir.path}/$saveAs';
	}

	static bool shouldSkipPlaybackFile(RequiredFile file) {
		if (file.saveAs.isEmpty) return true;

		final parts = file.saveAs.split('.');
		if (parts.length > 1) {
			final ext = parts.last.toLowerCase();
			if (_skipExtensions.contains(ext)) return true;
		}

		if (file.id == '1' && file.saveAs == '1.xlf') return true;
		if (ScheduleItem.isDefaultFallbackLayout(file.id) && file.saveAs.endsWith('.xlf')) {
			return true;
		}

		return false;
	}

	Future<bool> fileExists(String saveAs, String expectedMd5) async {
		final path = await getLocalPath(saveAs);
		final file = File(path);
		if (!await file.exists()) return false;
		if (expectedMd5.isEmpty) return true;
		final bytes = await file.readAsBytes();
		final digest = md5.convert(bytes).toString();
		return digest.toLowerCase() == expectedMd5.toLowerCase();
	}

	Future<void> downloadFile(RequiredFile file, {bool logFirstGetFile = false}) async {
		if (shouldSkipPlaybackFile(file)) {
			final ext = file.saveAs.contains('.') ? file.saveAs.split('.').last : file.saveAs;
			if (_skipExtensions.contains(ext.toLowerCase())) {
				PlayerLogger.log('DOWNLOAD', 'Skip font/JS: ${file.saveAs}');
			} else {
				PlayerLogger.log('DOWNLOAD', 'Skip default layout 1');
			}
			return;
		}

		final dir = await getAppStorageDir();
		final savePath = '${dir.path}/${file.saveAs}';

		final existing = File(savePath);
		if (await existing.exists() && file.md5.isNotEmpty) {
			final bytes = await existing.readAsBytes();
			final actualMd5 = md5.convert(bytes).toString();
			if (actualMd5.toLowerCase() == file.md5.toLowerCase()) {
				PlayerLogger.log('DOWNLOAD', 'Cached OK: ${file.saveAs}');
				return;
			}
			PlayerLogger.log('DOWNLOAD', 'MD5 mismatch — re-downloading: ${file.saveAs}');
		}

		if (file.isHttpDownload && file.path.isNotEmpty) {
			await _downloadViaHttp(file, savePath);
		} else {
			await _downloadViaGetFile(file, savePath, logFirstResponse: logFirstGetFile);
		}
	}

	Future<void> _downloadViaHttp(RequiredFile file, String savePath) async {
		PlayerLogger.log('DOWNLOAD', 'HTTP: ${file.saveAs}', data: {
			'url': file.path.substring(0, file.path.length.clamp(0, 100)),
		});

		try {
			final response = await _http.get<List<int>>(file.path);
			final bytes = response.data;
			if (bytes == null || bytes.isEmpty) {
				throw Exception('HTTP download empty for ${file.saveAs}');
			}

			if (file.md5.isNotEmpty) {
				final actualMd5 = md5.convert(bytes).toString();
				if (actualMd5.toLowerCase() != file.md5.toLowerCase()) {
					throw Exception(
						'MD5 mismatch for ${file.saveAs}: expected ${file.md5} got $actualMd5',
					);
				}
			}

			await File(savePath).writeAsBytes(bytes, flush: true);
			PlayerLogger.log('DOWNLOAD', 'HTTP OK: ${file.saveAs} (${bytes.length}B)');
		} catch (e, st) {
			PlayerLogger.error('DOWNLOAD', 'HTTP failed: ${file.saveAs}', e, st);
			rethrow;
		}
	}

	Future<void> _downloadViaGetFile(
		RequiredFile file,
		String savePath, {
		bool logFirstResponse = false,
	}) async {
		const maxChunk = AppConfig.chunkSize;
		int offset = 0;
		final allBytes = <int>[];
		var isFirstChunk = logFirstResponse;

		PlayerLogger.log('DOWNLOAD', 'XMDS GetFile: ${file.saveAs}', data: {
			'id': file.id,
			'type': file.type,
			'size': file.size,
		});

		if (file.size > 0) {
			while (offset < file.size) {
				final remaining = file.size - offset;
				final thisChunkSize = min(maxChunk, remaining);

				final chunk = await XmdsService.instance.getFileChunk(
					fileId: file.id,
					fileType: file.type,
					chunkOffset: offset,
					chunkSize: thisChunkSize,
					logResponse: isFirstChunk,
				);
				isFirstChunk = false;

				if (chunk.isEmpty) {
					if (offset == 0) {
						PlayerLogger.log('DOWNLOAD', 'ERROR: empty base64 chunk for ${file.saveAs}');
					}
					break;
				}

				allBytes.addAll(chunk);
				offset += chunk.length;
			}
		} else {
			final thisChunkSize = maxChunk;
			while (true) {
				final chunk = await XmdsService.instance.getFileChunk(
					fileId: file.id,
					fileType: file.type,
					chunkOffset: offset,
					chunkSize: thisChunkSize,
					logResponse: isFirstChunk,
				);
				isFirstChunk = false;

				if (chunk.isEmpty) break;
				allBytes.addAll(chunk);
				offset += chunk.length;
				if (chunk.length < thisChunkSize) break;
			}
		}

		if (allBytes.isEmpty) {
			throw Exception('No data received for ${file.saveAs}');
		}

		if (file.md5.isNotEmpty) {
			final digest = md5.convert(allBytes).toString();
			if (digest.toLowerCase() != file.md5.toLowerCase()) {
				throw Exception('MD5 mismatch for ${file.saveAs} (got $digest, expected ${file.md5})');
			}
		}

		await File(savePath).writeAsBytes(allBytes, flush: true);
		PlayerLogger.log('DOWNLOAD', 'XMDS GetFile OK: ${file.saveAs} (${allBytes.length}B)');
	}

	Future<List<RequiredFile>> downloadAllMissing(List<RequiredFile> requiredFiles) async {
		final dir = await getApplicationDocumentsDirectory();
		PlayerLogger.log('DOWNLOAD', 'Storage path: ${dir.path}');
		PlayerLogger.log('DOWNLOAD', 'Manifest total: ${requiredFiles.length}');

		final failed = <RequiredFile>[];
		final errors = <String, String>{};
		var successCount = 0;
		var failCount = 0;
		var skipCount = 0;
		var loggedFirstGetFile = false;

		for (final file in requiredFiles) {
			if (shouldSkipPlaybackFile(file)) {
				skipCount++;
				continue;
			}

			try {
				if (await fileExists(file.saveAs, file.md5)) {
					PlayerLogger.log('DOWNLOAD', 'Already present: ${file.saveAs}');
					successCount++;
					continue;
				}

				final logRaw = !loggedFirstGetFile && file.isXmdsDownload;
				if (logRaw) loggedFirstGetFile = true;
				await downloadFile(file, logFirstGetFile: logRaw);
				successCount++;
			} catch (e, st) {
				failCount++;
				failed.add(file);
				errors[file.saveAs] = e.toString();
				PlayerLogger.error('DOWNLOAD', 'FAILED: ${file.saveAs}', e, st);
			}
		}

		PlayerLogger.log('DOWNLOAD', 'Summary', data: {
			'manifest': requiredFiles.length,
			'skipped': skipCount,
			'success': successCount,
			'failed': failCount,
		});
		return failed;
	}

	Future<List<RequiredFile>> filterMissing(List<RequiredFile> files) async {
		final missing = <RequiredFile>[];
		final appDir = await getAppStorageDir();
		for (final file in files) {
			if (shouldSkipPlaybackFile(file)) continue;

			final path = '${appDir.path}/${file.saveAs}';
			if (!await File(path).exists()) {
				missing.add(file);
				continue;
			}
			if (file.md5.isNotEmpty && !await fileExists(file.saveAs, file.md5)) {
				missing.add(file);
			}
		}
		return missing;
	}

	static bool isDependencyFile(RequiredFile f) {
		return shouldSkipPlaybackFile(f);
	}

	static bool isLayoutFile(RequiredFile f) {
		return f.type == 'layout' || f.saveAs.toLowerCase().endsWith('.xlf');
	}

	static bool isCampaignMediaFile(RequiredFile f) {
		if (f.type != 'media' || shouldSkipPlaybackFile(f)) return false;
		final id = int.tryParse(f.id);
		return id != null && id > 0;
	}

	Future<bool> isFileOnDisk(RequiredFile file) async {
		if (shouldSkipPlaybackFile(file)) return false;
		final name = file.saveAs.isNotEmpty ? file.saveAs : file.id;
		if (name.isEmpty) return false;
		return fileExists(name, file.md5);
	}

	Future<DownloadProgress> computeDownloadProgress(List<RequiredFile> requiredFiles) async {
		var filesReady = 0;
		var playableTotal = 0;
		var depsReady = 0;
		var depsTotal = 0;
		var layoutsReady = 0;
		var layoutsTotal = 0;
		var mediaReady = 0;
		var mediaTotal = 0;

		for (final f in requiredFiles) {
			if (isDependencyFile(f)) {
				depsTotal++;
				if (await isFileOnDisk(f)) depsReady++;
				continue;
			}

			playableTotal++;
			final onDisk = await isFileOnDisk(f);
			if (onDisk) filesReady++;

			if (isLayoutFile(f)) {
				layoutsTotal++;
				if (onDisk) layoutsReady++;
			} else if (isCampaignMediaFile(f)) {
				mediaTotal++;
				if (onDisk) mediaReady++;
			}
		}

		return DownloadProgress(
			filesReady: filesReady,
			filesTotal: playableTotal,
			dependenciesReady: depsReady,
			dependenciesTotal: depsTotal,
			layoutsReady: layoutsReady,
			layoutsTotal: layoutsTotal,
			campaignMediaReady: mediaReady,
			campaignMediaTotal: mediaTotal,
		);
	}

	Future<int> countReadyMediaFiles(List<RequiredFile> requiredFiles) async {
		return (await computeDownloadProgress(requiredFiles)).campaignMediaReady;
	}

	Future<int> getFreeSpaceMB() async {
		try {
			final dir = await getAppStorageDir();
			final stat = await dir.stat();
			return (stat.size / (1024 * 1024)).floor().clamp(0, 999999);
		} catch (_) {
			return 0;
		}
	}

	/// True when RequiredFiles lists layout XLFs or image/video media (like official Xibo).
	static bool hasPlayableManifestContent(List<RequiredFile> files) {
		if (RequiredFile.layoutIdsFromFiles(files).isNotEmpty) return true;
		for (final f in files) {
			if (shouldSkipPlaybackFile(f)) continue;
			if (RequiredFile.isPlayableMediaFilename(f.saveAs)) return true;
		}
		return false;
	}

	static Set<String> layoutIdsForSchedule({
		required List<ScheduleItem> schedule,
		required String defaultLayoutId,
	}) {
		final ids = <String>{};
		for (final item in ScheduleItem.withoutDefaultFallback(schedule)) {
			if (item.layoutId.isNotEmpty) ids.add(item.layoutId);
		}
		if (ids.isEmpty) {
			final normalized = ScheduleItem.normalizeLayoutFileId(defaultLayoutId);
			if (normalized.isNotEmpty && !ScheduleItem.isDefaultFallbackLayout(normalized)) {
				ids.add(normalized);
			}
		}
		return ids;
	}

	/// Downloads scheduled layout XLFs then all playable RequiredFiles via HTTP or GetFile.
	Future<List<RequiredFile>> syncContentForSchedule({
		required List<ScheduleItem> schedule,
		required String defaultLayoutId,
		List<RequiredFile> knownRequired = const [],
	}) async {
		var required = knownRequired;
		if (required.isEmpty) {
			required = await XmdsService.instance.getRequiredFiles();
		}

		var scheduledLayouts = layoutIdsForSchedule(
			schedule: schedule,
			defaultLayoutId: defaultLayoutId,
		).toList();

		if (scheduledLayouts.isEmpty) {
			scheduledLayouts = RequiredFile.layoutIdsFromFiles(required);
			if (scheduledLayouts.isNotEmpty) {
				PlayerLogger.log('DOWNLOAD', 'Layout IDs from RequiredFiles: $scheduledLayouts');
			}
		}

		if (scheduledLayouts.isEmpty) {
			PlayerLogger.log('DOWNLOAD', 'No scheduled content');
			return required;
		}

		PlayerLogger.log('DOWNLOAD', 'syncContentForSchedule layouts=$scheduledLayouts');

		for (final layoutId in scheduledLayouts) {
			final xlfName = '$layoutId.xlf';
			final xlfFile = RequiredFile.findBySaveAs(required, xlfName);
			if (xlfFile == null) {
				PlayerLogger.log('DOWNLOAD', 'XLF $xlfName not in RequiredFiles — skipping');
				continue;
			}
			try {
				await downloadFile(xlfFile);
			} catch (e, st) {
				PlayerLogger.error('DOWNLOAD', 'XLF download failed $xlfName', e, st);
			}
		}

		for (final file in required) {
			try {
				await downloadFile(file);
			} catch (e, st) {
				PlayerLogger.error('DOWNLOAD', 'Failed ${file.saveAs}', e, st);
			}
		}

		required = await XmdsService.instance.getRequiredFiles();
		PlayerLogger.log('DOWNLOAD', 'RequiredFiles after sync: ${required.length}');
		return required;
	}
}
