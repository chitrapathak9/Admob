import '../core/logger.dart';
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

/// Runs one complete XMDS collection cycle (Phase F2.6):
///   1. GetSchedule
///   2. GetRequiredFiles + download missing
///   3. MediaInventory
///   4. Parse XLF → build playlist
///
/// All errors are caught and the last-cached playlist is returned so the
/// player never shows a blank screen due to a transient network failure.
class CollectionService {
	CollectionService._();
	static final CollectionService instance = CollectionService._();

	List<PlayItem> _cachedPlaylist = [];
	String _cachedLayoutId = '0';

	List<PlayItem> get cachedPlaylist => List.unmodifiable(_cachedPlaylist);

	Future<CollectionResult> runCollectionCycle() async {
		PlayerLogger.log('PLAYER', 'CollectionService cycle start');
		try {
			final scheduleResult = await XmdsService.instance.getScheduleWithDefault();
			PlayerLogger.log('PLAYER', 'GetSchedule layouts=${scheduleResult.schedule.length} default=${scheduleResult.defaultLayoutId}');

			var required = await XmdsService.instance.getRequiredFiles();
			PlayerLogger.log('PLAYER', 'RequiredFiles total=${required.length}');

			final missing = await DownloadService.instance.filterMissing(required);
			if (missing.isNotEmpty) {
				PlayerLogger.log('PLAYER', 'Downloading missing=${missing.length}');
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
				PlayerLogger.log('PLAYER', 'MediaInventory reporting=${mediaOnDisk.length}');
				await XmdsService.instance.mediaInventory(mediaOnDisk);
			}

			final build = await XlfParser.instance.buildPlaylistFromSchedule(
				schedule: scheduleResult.schedule,
				defaultLayoutId: scheduleResult.defaultLayoutId,
				requiredFiles: required,
			);

			PlayerLogger.log('PLAYER', 'Playlist built=${build.playlist.length} layoutId=${build.layoutId}');

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
			PlayerLogger.error('PLAYER', 'CollectionService cycle failed — using cache', e, st);
			return CollectionResult(playlist: _cachedPlaylist, layoutId: _cachedLayoutId);
		}
	}
}
