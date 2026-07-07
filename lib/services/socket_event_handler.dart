import 'package:disk_space_2/disk_space_2.dart';

import '../config/app_config.dart';
import '../models/screen_status_data.dart';
import '../utils/app_logger.dart';
import 'display_manager_service.dart';
import 'download_service.dart';
import 'screenshot_service.dart';
import 'screen_service.dart';
import 'socket_service.dart';
import 'storage_cleanup_service.dart';
import 'storage_service.dart';
import 'xmds_service.dart';

class SocketEventHandler {
	SocketEventHandler({
		SocketService? socketService,
		XmdsService? xmdsService,
		ScreenService? screenService,
		DownloadService? downloadService,
	})  : _socketService = socketService ?? SocketService.instance,
		_xmdsService = xmdsService ?? XmdsService.instance,
		_screenService = screenService ?? ScreenService.instance,
		_downloadService = downloadService ?? DownloadService.instance;

	static const _screenshotSocketEvents = AppConfig.screenshotSocketEvents;

	final SocketService _socketService;
	final XmdsService _xmdsService;
	final ScreenService _screenService;
	final DownloadService _downloadService;
	bool _registered = false;
	int _registeredOnGeneration = -1;

	void registerAll() {
		final generation = _socketService.socketGeneration;
		if (_registered && _registeredOnGeneration == generation) {
			AppLogger.socket('Socket listeners already registered — skip');
			return;
		}
		if (_registered) {
			unregisterAll();
		}
		_registered = true;
		_registeredOnGeneration = generation;
		_onScreenApproved();
		_onSyncNow();
		_onContentUpdated();
		_onScheduleActivated();
		_onSchedulePaused();
		_onScreenBlankState();
		_onScreenshotRequested();
		_onWrappedScreenEvents();
		_onScreenshotCatchAll();
		_onStorageInfoRequested();
		_onStorageClearRequested();
		_onGetDisplayCount();
		AppLogger.socket('All socket event listeners registered (socketGen=$generation)');
	}

	void unregisterAll() {
		if (!_registered) return;
		_registered = false;
		_registeredOnGeneration = -1;
		_socketService.off('screen:approved');
		_socketService.off('sync:now');
		_socketService.off('content:updated');
		_socketService.off('schedule:activated');
		_socketService.off('schedule:paused');
		_socketService.off('screen:blank-state');
		_socketService.off('screen:storage:info:request');
		_socketService.off('screen:storage:clear:request');
		_socketService.off('get_display_count');
		for (final event in _screenshotSocketEvents) {
			_socketService.off(event);
		}
		for (final event in _wrappedScreenEvents) {
			_socketService.off(event);
		}
	}

	static const _wrappedScreenEvents = [
		'message',
		'screen:event',
		'player:event',
		'command',
		'screen:command',
		'player:command',
	];

	void _onScreenApproved() {
		_socketService.on('screen:approved', (data) async {
			AppLogger.socketEventReceived('screen:approved', data);
			await _safe(() async {
				await refreshScreenStatus();
				await _registerAndSyncAfterApproval();
				SocketEventBus.instance.emit(SocketEvent.screenApproved, data);
			});
		});
	}

	void _onSyncNow() {
		_socketService.on('sync:now', (data) async {
			AppLogger.socketEventReceived('sync:now', data);
			await _safe(() async {
				await _syncRequiredFilesAndDownload();
				await _xmdsService.getSchedule();
				SocketEventBus.instance.emit(SocketEvent.syncNow, data);
			});
		});
	}

	void _onContentUpdated() {
		_socketService.on('content:updated', (data) async {
			AppLogger.socketEventReceived('content:updated', data);
			await _safe(() async {
				await _syncRequiredFilesAndDownload();
				SocketEventBus.instance.emit(SocketEvent.contentUpdated, data);
			});
		});
	}

	void _onScheduleActivated() {
		_socketService.on('schedule:activated', (data) async {
			AppLogger.socketEventReceived('schedule:activated', data);
			await _safe(() async {
				await _xmdsService.getSchedule();
				SocketEventBus.instance.emit(SocketEvent.scheduleActivated, data);
			});
		});
	}

	void _onSchedulePaused() {
		_socketService.on('schedule:paused', (data) async {
			AppLogger.socketEventReceived('schedule:paused', data);
			await _safe(() async {
				await _xmdsService.getSchedule();
				SocketEventBus.instance.emit(SocketEvent.schedulePaused, data);
			});
		});
	}

	void _onScreenBlankState() {
		_socketService.on('screen:blank-state', (data) async {
			AppLogger.socketEventReceived('screen:blank-state', data);
			await _safe(() async {
				SocketEventBus.instance.emit(SocketEvent.screenBlankState, data);
			});
		});
	}

	void _onScreenshotRequested() {
		for (final event in _screenshotSocketEvents) {
			_socketService.off(event);
			_socketService.on(event, (data) async {
				AppLogger.screenshotEventReceived('Socket.io', event, data);
				await _handleScreenshotEvent(event, data);
			});
			AppLogger.screenshotEvent('READY — listening for socket event: $event (not received yet)');
		}
	}

	Future<void> _handleScreenshotEvent(String event, dynamic data) async {
		final requestId = _readRequestId(data);
		final displayTarget = data is Map
			? (data['displayTarget'] as String? ?? 'primary')
			: 'primary';
		AppLogger.screenshotEvent(
			'Step 1 — handling event="$event" requestId=${requestId ?? "(none)"} displayTarget=$displayTarget',
		);
		await _safe(() async {
			await ScreenshotService.instance.captureAndUpload(
				requestId: requestId,
				displayTarget: displayTarget,
			);
			SocketEventBus.instance.emit(SocketEvent.screenshotRequested, data);
			AppLogger.screenshotEvent('Step 3 DONE — event="$event" handled');
		});
	}

	void _onStorageInfoRequested() {
		_socketService.on('screen:storage:info:request', (data) async {
			AppLogger.socketEventReceived('screen:storage:info:request', data);
			await _safe(() async {
				final hardwareKey = await StorageService.instance.loadHardwareKey();
				if (hardwareKey == null) return;
				final usedMb = await _downloadService.getMediaDirUsedMB();
				final totalMbRaw = await DiskSpace.getTotalDiskSpace;
				final freeMbRaw = await DiskSpace.getFreeDiskSpace;
				await _screenService.sendStorageInfo(
					hardwareKey: hardwareKey,
					usedMb: usedMb,
					totalMb: (totalMbRaw ?? 0).round(),
					freeMb: (freeMbRaw ?? 0).round(),
				);
			});
		});
	}

	void _onStorageClearRequested() {
		_socketService.on('screen:storage:clear:request', (data) async {
			AppLogger.socketEventReceived('screen:storage:clear:request', data);
			await _safe(() async {
				final hardwareKey = await StorageService.instance.loadHardwareKey();
				if (hardwareKey == null) return;
				final freedMb = await StorageCleanupService.instance.forceClearUnused();
				await _screenService.sendStorageClear(
					hardwareKey: hardwareKey,
					freedMb: freedMb,
				);
			});
		});
	}

	/// Backend forwards `get_display_count` from the admin panel to this device.
	/// Responds immediately with the number of physical displays the OS reports.
	void _onGetDisplayCount() {
		_socketService.on('get_display_count', (data) {
			AppLogger.socketEventReceived('get_display_count', data);
			final displayId =
				data is Map ? (data['displayId'] as num?)?.toInt() ?? 0 : 0;
			final payload =
				DisplayManagerService.instance.getDisplayCountPayload(displayId);
			_socketService.emit('display_count_response', payload);
		});
	}

	void _onWrappedScreenEvents() {
		for (final wrapper in _wrappedScreenEvents) {
			_socketService.off(wrapper);
			_socketService.on(wrapper, (data) async {
				AppLogger.socketEventReceived(wrapper, data);
				final innerEvent = _readInnerEventName(data);
				if (innerEvent == null) return;
				if (!_isScreenshotEventName(innerEvent)) return;
				AppLogger.screenshotEvent('Step 1 — wrapped event "$wrapper" inner="$innerEvent"');
				await _handleScreenshotEvent(innerEvent, _readInnerPayload(data));
			});
			AppLogger.screenshotEvent('READY — listening for wrapped event: $wrapper (not received yet)');
		}
	}

	/// Handles screenshot events whose top-level name is not in [AppConfig.screenshotSocketEvents].
	void _onScreenshotCatchAll() {
		_socketService.onAny((event, data) async {
			if (_screenshotSocketEvents.contains(event)) return;
			if (!_isScreenshotEventName(event)) return;
			AppLogger.screenshotEvent('Step 1 — catch-all direct event "$event"');
			await _handleScreenshotEvent(event, data);
		});
	}

	String? _readInnerEventName(dynamic data) {
		if (data is! Map) return null;
		final event = data['event'] ?? data['type'] ?? data['action'] ?? data['command'] ?? data['name'];
		if (event == null) return null;
		final value = event.toString().trim();
		return value.isEmpty ? null : value;
	}

	dynamic _readInnerPayload(dynamic data) {
		if (data is! Map) return data;
		return data['data'] ?? data['payload'] ?? data;
	}

	bool _isScreenshotEventName(String name) => AppConfig.isScreenshotSocketEvent(name);

	String? _readRequestId(dynamic data) {
		if (data is! Map) return null;
		final requestId = data['requestId'];
		if (requestId == null) return null;
		final value = requestId.toString().trim();
		return value.isEmpty ? null : value;
	}

	Future<ScreenStatusData?> refreshScreenStatus() async {
		final hardwareKey = await StorageService.instance.loadHardwareKey();
		if (hardwareKey == null || hardwareKey.isEmpty) return null;

		try {
			final status = await _screenService.getStatus(hardwareKey);
			await StorageService.instance.saveRegistrationStatus(status.status);
			if (status.isApprovedOrActive) {
				await StorageService.instance.setApproved(true);
			}
			return status;
		} on ScreenApiException catch (e) {
			if (e.isNotRegistered) {
				AppLogger.status('Device not registered — clearing local registration');
				await StorageService.instance.clearAll();
				SocketEventBus.instance.emit(SocketEvent.deviceNotRegistered, e);
			}
			rethrow;
		}
	}

	Future<void> _registerAndSyncAfterApproval() async {
		final displayName = await StorageService.instance.loadDisplayName();
		if (displayName != null && displayName.isNotEmpty) {
			await _xmdsService.registerDisplay(displayName);
		}
		await _syncRequiredFilesAndDownload();
		await _xmdsService.getSchedule();
	}

	Future<void> _syncRequiredFilesAndDownload() async {
		final files = await _xmdsService.getRequiredFiles();
		final missing = await _downloadService.filterMissing(files);
		if (missing.isNotEmpty) {
			await _downloadService.downloadAllMissing(missing);
		}
	}

	Future<void> catchUpAfterReconnect() async {
		await _safe(() async {
			await refreshScreenStatus();
			await _syncRequiredFilesAndDownload();
			await _xmdsService.getSchedule();
		});
	}

	Future<void> _safe(Future<void> Function() action) async {
		try {
			await action();
		} catch (e, st) {
			AppLogger.apiError('Socket', 'Event handler failed', e, st);
		}
	}
}
