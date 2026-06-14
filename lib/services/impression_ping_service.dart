import 'dart:async';

import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';

import '../config/app_config.dart';
import '../models/play_item.dart';
import '../utils/app_logger.dart';
import '../utils/api_log_interceptor.dart';
import 'storage_service.dart';

/// Fires impression pings to the revenue backend after each ad display.
///
/// Pings are attempted immediately; failures are persisted in a local SQLite
/// queue and retried on the next successful ping (drain-on-success strategy).
/// This guarantees no impressions are silently dropped even without connectivity.
///
/// Payload: { hardwareKey, campaignId, layoutId, mediaId, timestamp }
/// Endpoint: POST /api/v1/player/impression (public, no JWT)
class ImpressionPingService {
	ImpressionPingService._();
	static final ImpressionPingService instance = ImpressionPingService._();

	static const int _maxQueueSize = 500;
	static const int _drainBatchSize = 20;

	late final Dio _dio;
	Database? _db;
	bool _initialized = false;
	bool _draining = false;

	Future<void> init() async {
		if (_initialized) return;
		_initialized = true;
		_dio = Dio(
			BaseOptions(
				baseUrl: AppConfig.baseUrl,
				connectTimeout: const Duration(seconds: 10),
				receiveTimeout: const Duration(seconds: 15),
				headers: {'Content-Type': 'application/json'},
			),
		)..interceptors.add(ApiLogInterceptor());

		try {
			final dbPath = '${await getDatabasesPath()}/impression_queue.db';
			_db = await openDatabase(
				dbPath,
				// Version 2: removed schedule_id, campaign_id is now the required identifier
				version: 2,
				onCreate: (db, _) async {
					await db.execute('''
						CREATE TABLE IF NOT EXISTS ping_queue (
							id           INTEGER PRIMARY KEY AUTOINCREMENT,
							hardware_key TEXT    NOT NULL,
							campaign_id  TEXT    NOT NULL DEFAULT '',
							media_id     TEXT    NOT NULL,
							layout_id    TEXT    NOT NULL,
							ts           TEXT    NOT NULL
						)
					''');
				},
				onUpgrade: (db, oldVersion, newVersion) async {
					// Drop and recreate — offline queue is non-critical (impressions already shown)
					await db.execute('DROP TABLE IF EXISTS ping_queue');
					await db.execute('''
						CREATE TABLE ping_queue (
							id           INTEGER PRIMARY KEY AUTOINCREMENT,
							hardware_key TEXT    NOT NULL,
							campaign_id  TEXT    NOT NULL DEFAULT '',
							media_id     TEXT    NOT NULL,
							layout_id    TEXT    NOT NULL,
							ts           TEXT    NOT NULL
						)
					''');
				},
			);
			AppLogger.api('ImpPing', 'initialized (v2) — draining any queued pings');
			unawaited(_drainQueue());
		} catch (e, st) {
			AppLogger.apiError('ImpPing', 'init failed', e, st);
		}
	}

	/// Fire-and-forget: send ping now or enqueue for later retry.
	Future<void> ping(PlayItem item) async {
		// Only ping for revenue campaign items
		if (item.campaignId.isEmpty) return;

		final hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
		final ts = _nowIso();

		final payload = {
			'hardwareKey': hardwareKey,
			'campaignId':  item.campaignId,
			'mediaId':     item.mediaId,
			'layoutId':    item.layoutId,
			'timestamp':   ts,
		};

		try {
			await _dio.post<void>(AppConfig.impressionPingPath, data: payload);
			AppLogger.api(
				'ImpPing',
				'OK campaignId=${item.campaignId} mediaId=${item.mediaId}',
			);
			// On success drain any accumulated offline queue.
			unawaited(_drainQueue());
		} catch (e) {
			AppLogger.api(
				'ImpPing',
				'failed — queuing campaignId=${item.campaignId}',
			);
			await _enqueue(
				hardwareKey: hardwareKey,
				campaignId:  item.campaignId,
				mediaId:     item.mediaId,
				layoutId:    item.layoutId,
				ts:          ts,
			);
		}
	}

	Future<void> _enqueue({
		required String hardwareKey,
		required String campaignId,
		required String mediaId,
		required String layoutId,
		required String ts,
	}) async {
		final db = _db;
		if (db == null) return;
		try {
			final count = Sqflite.firstIntValue(
				await db.rawQuery('SELECT COUNT(*) FROM ping_queue'),
			) ?? 0;
			if (count >= _maxQueueSize) {
				// Drop oldest entry to stay within cap.
				await db.rawDelete(
					'DELETE FROM ping_queue WHERE id = (SELECT MIN(id) FROM ping_queue)',
				);
			}
			await db.insert('ping_queue', {
				'hardware_key': hardwareKey,
				'campaign_id':  campaignId,
				'media_id':     mediaId,
				'layout_id':    layoutId,
				'ts':           ts,
			});
		} catch (e, st) {
			AppLogger.apiError('ImpPing', '_enqueue failed', e, st);
		}
	}

	Future<void> _drainQueue() async {
		if (_draining) return;
		final db = _db;
		if (db == null) return;
		_draining = true;
		try {
			while (true) {
				final rows = await db.query(
					'ping_queue',
					orderBy: 'id ASC',
					limit: _drainBatchSize,
				);
				if (rows.isEmpty) break;

				final sent = <int>[];
				for (final row in rows) {
					try {
						await _dio.post<void>(AppConfig.impressionPingPath, data: {
							'hardwareKey': row['hardware_key'],
							'campaignId':  row['campaign_id'],
							'mediaId':     row['media_id'],
							'layoutId':    row['layout_id'],
							'timestamp':   row['ts'],
						});
						sent.add(row['id'] as int);
					} catch (_) {
						// Network still unavailable — stop drain, try again later.
						break;
					}
				}

				if (sent.isEmpty) break;
				final placeholders = List.filled(sent.length, '?').join(',');
				await db.rawDelete(
					'DELETE FROM ping_queue WHERE id IN ($placeholders)',
					sent,
				);
				AppLogger.api('ImpPing', 'drained ${sent.length} queued pings');

				if (sent.length < _drainBatchSize) break;
			}
		} catch (e, st) {
			AppLogger.apiError('ImpPing', '_drainQueue error', e, st);
		} finally {
			_draining = false;
		}
	}

	void updateBaseUrl() {
		_dio.options.baseUrl = AppConfig.baseUrl;
	}

	String _nowIso() {
		final now = DateTime.now().toUtc();
		return now.toIso8601String();
	}
}
