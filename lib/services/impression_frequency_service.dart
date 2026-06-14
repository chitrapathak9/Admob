import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../models/play_item.dart';
import '../utils/app_logger.dart';

class _FrequencyLimits {
	final int maxPerDay;
	final int maxPerMonth;
	final int dailyCapPerScreen;

	const _FrequencyLimits({
		required this.maxPerDay,
		required this.maxPerMonth,
		required this.dailyCapPerScreen,
	});

	bool get isUnlimited =>
		maxPerDay == 0 && maxPerMonth == 0 && dailyCapPerScreen == 0;
}

class _CampaignCounts {
	final Map<String, int> daily = {};
	final Map<String, int> monthly = {};
}

/// Tracks per-campaign impression frequency using an in-memory cache (sync
/// reads) backed by sqflite (async writes + persistence across restarts).
///
/// Keyed by campaignId (UUID string from the revenue Campaign entity).
/// Items with an empty campaignId are always shown (non-revenue content).
/// Limits of 0 are treated as unlimited.
class ImpressionFrequencyService {
	ImpressionFrequencyService._();
	static final ImpressionFrequencyService instance =
		ImpressionFrequencyService._();

	Database? _db;
	final Map<String, _FrequencyLimits> _limits = {};
	final Map<String, _CampaignCounts> _counts = {};
	bool _initialized = false;

	Future<void> init() async {
		if (_initialized) return;
		_initialized = true;
		try {
			final dbPath = '${await getDatabasesPath()}/impression_freq.db';
			_db = await openDatabase(
				dbPath,
				// Version 2: replaced schedule_id INTEGER key with campaign_id TEXT key
				version: 2,
				onCreate: (db, _) async {
					await db.execute('''
						CREATE TABLE IF NOT EXISTS impression_counts (
							campaign_id  TEXT    NOT NULL,
							period_key   TEXT    NOT NULL,
							period_type  TEXT    NOT NULL,
							count        INTEGER NOT NULL DEFAULT 0,
							PRIMARY KEY (campaign_id, period_key, period_type)
						)
					''');
				},
				onUpgrade: (db, oldVersion, newVersion) async {
					// Drop and recreate — frequency data is non-critical (just tracking counts)
					await db.execute('DROP TABLE IF EXISTS impression_counts');
					await db.execute('''
						CREATE TABLE impression_counts (
							campaign_id  TEXT    NOT NULL,
							period_key   TEXT    NOT NULL,
							period_type  TEXT    NOT NULL,
							count        INTEGER NOT NULL DEFAULT 0,
							PRIMARY KEY (campaign_id, period_key, period_type)
						)
					''');
				},
			);
			await _loadCurrentPeriodCounts();
			unawaited(pruneOldRecords());
			AppLogger.api('ImpFreq', 'initialized (v2, keyed by campaignId)');
		} catch (e, st) {
			AppLogger.apiError('ImpFreq', 'init failed', e, st);
		}
	}

	Future<void> _loadCurrentPeriodCounts() async {
		final db = _db;
		if (db == null) return;
		final today = _todayKey();
		final month = _monthKey();
		final rows = await db.query(
			'impression_counts',
			where: 'period_key = ? OR period_key = ?',
			whereArgs: [today, month],
		);
		for (final row in rows) {
			final campaignId = row['campaign_id'] as String;
			final periodKey = row['period_key'] as String;
			final periodType = row['period_type'] as String;
			final count = row['count'] as int;
			final counts = _counts.putIfAbsent(campaignId, () => _CampaignCounts());
			if (periodType == 'daily') {
				counts.daily[periodKey] = count;
			} else {
				counts.monthly[periodKey] = count;
			}
		}
	}

	/// Called after each manifest refresh to register per-campaign limits.
	void updateLimits(List<PlayItem> playlist) {
		for (final item in playlist) {
			if (item.campaignId.isEmpty) continue;
			_limits[item.campaignId] = _FrequencyLimits(
				maxPerDay: item.maxPerDay,
				maxPerMonth: item.maxPerMonth,
				dailyCapPerScreen: item.dailyCapPerScreen,
			);
		}
	}

	/// Synchronous check against the in-memory cache — safe to call during
	/// setState or in the playlist loop without blocking the UI thread.
	bool shouldShow(PlayItem item) {
		// Non-revenue content (no campaignId) is always allowed
		if (item.campaignId.isEmpty) return true;

		final limits = _limits[item.campaignId];
		if (limits == null || limits.isUnlimited) return true;

		final today = _todayKey();
		final month = _monthKey();
		final counts = _counts[item.campaignId];
		final dailyCount = counts?.daily[today] ?? 0;
		final monthlyCount = counts?.monthly[month] ?? 0;

		if (limits.maxPerDay > 0 && dailyCount >= limits.maxPerDay) return false;
		if (limits.dailyCapPerScreen > 0 && dailyCount >= limits.dailyCapPerScreen) {
			return false;
		}
		if (limits.maxPerMonth > 0 && monthlyCount >= limits.maxPerMonth) return false;

		return true;
	}

	/// Records one impression for [item]. Updates the in-memory cache
	/// immediately and persists to sqlite asynchronously.
	Future<void> recordImpression(PlayItem item) async {
		if (item.campaignId.isEmpty) return;

		final today = _todayKey();
		final month = _monthKey();
		final counts = _counts.putIfAbsent(item.campaignId, () => _CampaignCounts());
		counts.daily[today] = (counts.daily[today] ?? 0) + 1;
		counts.monthly[month] = (counts.monthly[month] ?? 0) + 1;

		final db = _db;
		if (db == null) return;
		try {
			// INSERT OR IGNORE + UPDATE is compatible with all SQLite versions.
			await db.rawInsert(
				'INSERT OR IGNORE INTO impression_counts '
				'(campaign_id, period_key, period_type, count) VALUES (?, ?, ?, 0)',
				[item.campaignId, today, 'daily'],
			);
			await db.rawUpdate(
				'UPDATE impression_counts SET count = count + 1 '
				'WHERE campaign_id = ? AND period_key = ? AND period_type = ?',
				[item.campaignId, today, 'daily'],
			);
			await db.rawInsert(
				'INSERT OR IGNORE INTO impression_counts '
				'(campaign_id, period_key, period_type, count) VALUES (?, ?, ?, 0)',
				[item.campaignId, month, 'monthly'],
			);
			await db.rawUpdate(
				'UPDATE impression_counts SET count = count + 1 '
				'WHERE campaign_id = ? AND period_key = ? AND period_type = ?',
				[item.campaignId, month, 'monthly'],
			);
		} catch (e, st) {
			AppLogger.apiError('ImpFreq', 'recordImpression persist failed', e, st);
		}
	}

	/// Removes daily records older than 35 days to keep the database compact.
	Future<void> pruneOldRecords() async {
		final db = _db;
		if (db == null) return;
		try {
			final cutoff = DateTime.now().subtract(const Duration(days: 35));
			final cutoffKey = _fmtDate(cutoff);
			await db.delete(
				'impression_counts',
				where: 'period_type = ? AND period_key < ?',
				whereArgs: ['daily', cutoffKey],
			);
		} catch (e, st) {
			AppLogger.apiError('ImpFreq', 'pruneOldRecords failed', e, st);
		}
	}

	String _todayKey() => _fmtDate(DateTime.now());

	String _monthKey() {
		final now = DateTime.now();
		return '${now.year.toString().padLeft(4, '0')}-'
			'${now.month.toString().padLeft(2, '0')}';
	}

	String _fmtDate(DateTime d) =>
		'${d.year.toString().padLeft(4, '0')}-'
		'${d.month.toString().padLeft(2, '0')}-'
		'${d.day.toString().padLeft(2, '0')}';
}
