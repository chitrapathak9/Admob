import 'dart:developer' as developer;

import '../models/play_item.dart';
import '../models/required_file.dart';
import 'download_service.dart';
import 'storage_service.dart';
import 'xlf_parser.dart';
import 'xmds_service.dart';

class CollectionResult {
	final List<PlayItem> playlist;
	final String layoutId;

	const CollectionResult({required this.playlist, required this.layoutId});
}

class CollectionService {
	CollectionService._();
	static final CollectionService instance = CollectionService._();

	List<PlayItem> _cachedPlaylist = [];
	String _cachedLayoutId = '0';

	List<PlayItem> get cachedPlaylist => List.unmodifiable(_cachedPlaylist);

	Future<CollectionResult> runCollectionCycle() async {
		try {
			final scheduleResult = await XmdsService.instance.getScheduleWithDefault();

			var required = await XmdsService.instance.getRequiredFiles();
			final missing = await DownloadService.instance.filterMissing(required);
			if (missing.isNotEmpty) {
				await DownloadService.instance.downloadAllMissing(missing);
			}

			required = await DownloadService.instance.syncContentForSchedule(
				schedule: scheduleResult.schedule,
				defaultLayoutId: scheduleResult.defaultLayoutId,
				knownRequired: required,
			);

			final mediaOnDisk = <RequiredFile>[];
			for (final f in required.where((f) => f.type == 'media' && f.isXmdsDownload)) {
				if (await DownloadService.instance.fileExists(f.saveAs, f.md5)) {
					mediaOnDisk.add(f);
				}
			}
			if (mediaOnDisk.isNotEmpty) {
				await XmdsService.instance.mediaInventory(mediaOnDisk);
			}

			final build = await XlfParser.instance.buildPlaylistFromSchedule(
				schedule: scheduleResult.schedule,
				defaultLayoutId: scheduleResult.defaultLayoutId,
				requiredFiles: required,
			);

			if (build.layoutId.isNotEmpty) {
				await StorageService.instance.setCurrentLayoutId(build.layoutId);
			}

			if (build.playlist.isNotEmpty) {
				_cachedPlaylist = build.playlist;
				_cachedLayoutId = build.layoutId;
			}

			return CollectionResult(
				playlist: build.playlist.isNotEmpty ? build.playlist : _cachedPlaylist,
				layoutId: build.layoutId.isNotEmpty ? build.layoutId : _cachedLayoutId,
			);
		} catch (e, st) {
			developer.log('Collection cycle failed: $e', error: e, stackTrace: st);
			return CollectionResult(playlist: _cachedPlaylist, layoutId: _cachedLayoutId);
		}
	}
}
