import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/player_manifest.dart';
import '../utils/app_logger.dart';
import 'download_service.dart';

/// Manages all 3 storage-protection layers:
///
///  Layer 1 — Storage threshold: runs on every manifest refresh; if /media/ usage
///             exceeds [storageThresholdMb] from the manifest, prune stale files
///             (minAge = 1h so currently-cycling files are safe).
///
///  Layer 2 — Campaign end: when manifest hash changes (content swap), prune
///             files no longer in the new keep set immediately (minAge = 0h)
///             because the old campaign is definitively over.
///
///  Layer 3 — Hourly sweep: independent Timer runs every hour and deletes
///             anything not in the current keep set that is older than 24h.
///
/// Safety invariant: cleanup never runs when [_keepFilenames] is empty — this
/// protects the gap between campaigns where the manifest returns media:[].
class StorageCleanupService {
	StorageCleanupService._();
	static final StorageCleanupService instance = StorageCleanupService._();

	Set<String> _keepFilenames = {};
	int _thresholdMb = 1024;
	Timer? _hourlyTimer;
	bool _cleaning = false;

	// ── Lifecycle ───────────────────────────────────────────────────────────────

	void start() {
		_hourlyTimer?.cancel();
		_hourlyTimer = Timer.periodic(const Duration(hours: 1), (_) {
			unawaited(_runCleanup(minAgeHours: 24, reason: 'hourly'));
		});
		AppLogger.download('[StorageCleanup] hourly sweep started');
	}

	void stop() {
		_hourlyTimer?.cancel();
		_hourlyTimer = null;
		AppLogger.download('[StorageCleanup] stopped');
	}

	// ── Called by player_screen after every successful manifest fetch ────────────

	/// [contentChanged] = true when manifest hash changed (campaign ended / swapped).
	void onManifestUpdated(PlayerManifest manifest, {bool contentChanged = false}) {
		// Never update keep set from an empty manifest — we're in a between-campaign
		// gap and don't want to wipe files that the next campaign may still need.
		if (manifest.media.isEmpty) return;

		_keepFilenames = manifest.media.map((m) => m.filename).toSet();
		_thresholdMb = manifest.storageThresholdMb;

		if (contentChanged) {
			// Campaign ended / content swapped — delete old files immediately.
			unawaited(_runCleanup(minAgeHours: 0, reason: 'campaign-end'));
		} else {
			// Normal refresh — only clean if over storage threshold.
			unawaited(_checkThreshold());
		}
	}

	// ── Internal ────────────────────────────────────────────────────────────────

	Future<void> _checkThreshold() async {
		final usedMb = await DownloadService.instance.getMediaDirUsedMB();
		debugPrint('[StorageCleanup] used=${usedMb}MB threshold=${_thresholdMb}MB');
		if (usedMb > _thresholdMb) {
			await _runCleanup(minAgeHours: 1, reason: 'threshold');
		}
	}

	Future<void> _runCleanup({required int minAgeHours, required String reason}) async {
		if (_cleaning) return;
		if (_keepFilenames.isEmpty) {
			AppLogger.download('[StorageCleanup:$reason] skipped — keep set is empty');
			return;
		}

		_cleaning = true;
		try {
			final usedBefore = await DownloadService.instance.getMediaDirUsedMB();
			final freedMb = await DownloadService.instance.pruneUnusedMedia(
				_keepFilenames,
				minAgeHours: minAgeHours,
			);
			final usedAfter = usedBefore - freedMb;
			AppLogger.download(
				'[StorageCleanup:$reason] before=${usedBefore}MB freed=${freedMb}MB after=${usedAfter}MB '
				'(minAge=${minAgeHours}h keep=${_keepFilenames.length} files)',
			);
		} catch (e, st) {
			AppLogger.apiError('StorageCleanup', reason, e, st);
		} finally {
			_cleaning = false;
		}
	}

	/// Forces an immediate cleanup of unused files, ignoring age requirements.
	/// Returns the number of MB freed.
	Future<int> forceClearUnused() async {
		if (_keepFilenames.isEmpty) {
			AppLogger.download('[StorageCleanup:forceClearUnused] skipped — keep set is empty');
			return 0;
		}
		if (_cleaning) return 0;
		_cleaning = true;
		try {
			final freedMb = await DownloadService.instance.pruneUnusedMedia(
				_keepFilenames,
				minAgeHours: 0,
			);
			AppLogger.download('[StorageCleanup:forceClearUnused] freed=${freedMb}MB');
			return freedMb;
		} catch (e, st) {
			AppLogger.apiError('StorageCleanup', 'forceClearUnused', e, st);
			return 0;
		} finally {
			_cleaning = false;
		}
	}
}
