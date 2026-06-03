import 'dart:async';

import '../config/app_config.dart';
import '../utils/app_logger.dart';
import 'player_service.dart';
import 'storage_service.dart';

typedef PlayingNameProvider = String? Function();

/// REST heartbeat timer — separate from Socket.io online/offline detection.
class HeartbeatService {
	HeartbeatService._();
	static final HeartbeatService instance = HeartbeatService._();

	Timer? _timer;
	PlayingNameProvider? _playingNameProvider;
	Future<void> Function()? _onRefresh;

	void start({
		required PlayingNameProvider playingNameProvider,
		required Future<void> Function() onRefresh,
	}) {
		_playingNameProvider = playingNameProvider;
		_onRefresh = onRefresh;
		_timer?.cancel();
		_timer = Timer.periodic(
			const Duration(seconds: AppConfig.heartbeatIntervalSeconds),
			(_) => unawaited(_sendPlayingHeartbeat()),
		);
		unawaited(_sendPlayingHeartbeat());
		AppLogger.heartbeat('Timer started (every ${AppConfig.heartbeatIntervalSeconds}s)');
	}

	void stop() {
		_timer?.cancel();
		_timer = null;
		_playingNameProvider = null;
		_onRefresh = null;
		AppLogger.heartbeat('Timer stopped');
	}

	bool get isRunning => _timer != null;
	bool _pausedForBackground = false;

	/// Pause playing heartbeats while backgrounded so they don't override offline status.
	void pauseForBackground() {
		_pausedForBackground = true;
		AppLogger.heartbeat('Paused for background');
	}

	void resumeFromBackground() {
		_pausedForBackground = false;
		AppLogger.heartbeat('Resumed from background');
	}

	/// App kill / shutdown — stop timer then notify server.
	Future<void> shutdown() async {
		stop();
		await sendOffline();
	}

	/// Notify server offline via REST (reliable fallback for socket emit).
	Future<void> notifyOffline() => sendOffline();

	Future<void> _sendPlayingHeartbeat() async {
		if (_pausedForBackground) return;
		try {
			final hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
			final currentName = _playingNameProvider?.call();

			final result = await PlayerService.instance.sendHeartbeat(
				hardwareKey: hardwareKey,
				status: 'playing',
				currentFilename: currentName,
			);

			if (result.shouldRefresh) {
				AppLogger.heartbeat('Server requested refresh — updating playlist');
				await _onRefresh?.call();
			}
		} catch (e, st) {
			AppLogger.apiError('Heartbeat', 'periodic heartbeat failed (silent)', e, st);
		}
	}

	/// Sent when the app is killed or the engine is shutting down.
	Future<void> sendOffline() async {
		try {
			final hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
			AppLogger.heartbeat('Sending offline heartbeat');
			await PlayerService.instance.sendHeartbeat(
				hardwareKey: hardwareKey,
				status: 'offline',
			);
		} catch (e, st) {
			AppLogger.apiError('Heartbeat', 'offline heartbeat failed (silent)', e, st);
		}
	}
}
