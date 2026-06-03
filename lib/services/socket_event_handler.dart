import '../models/screen_status_data.dart';
import '../utils/app_logger.dart';
import 'download_service.dart';
import 'screen_service.dart';
import 'socket_service.dart';
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

	final SocketService _socketService;
	final XmdsService _xmdsService;
	final ScreenService _screenService;
	final DownloadService _downloadService;

	void registerAll() {
		_onScreenApproved();
		_onSyncNow();
		_onContentUpdated();
		_onScheduleActivated();
		_onSchedulePaused();
	}

	void unregisterAll() {
		_socketService.off('screen:approved');
		_socketService.off('sync:now');
		_socketService.off('content:updated');
		_socketService.off('schedule:activated');
		_socketService.off('schedule:paused');
	}

	void _onScreenApproved() {
		_socketService.on('screen:approved', (data) async {
			AppLogger.socket('screen:approved received');
			await _safe(() async {
				await refreshScreenStatus();
				await _registerAndSyncAfterApproval();
				SocketEventBus.instance.emit(SocketEvent.screenApproved, data);
			});
		});
	}

	void _onSyncNow() {
		_socketService.on('sync:now', (data) async {
			AppLogger.socket('sync:now received');
			await _safe(() async {
				await _syncRequiredFilesAndDownload();
				await _xmdsService.getSchedule();
				SocketEventBus.instance.emit(SocketEvent.syncNow, data);
			});
		});
	}

	void _onContentUpdated() {
		_socketService.on('content:updated', (data) async {
			AppLogger.socket('content:updated received');
			await _safe(() async {
				await _syncRequiredFilesAndDownload();
				SocketEventBus.instance.emit(SocketEvent.contentUpdated, data);
			});
		});
	}

	void _onScheduleActivated() {
		_socketService.on('schedule:activated', (data) async {
			AppLogger.socket('schedule:activated received');
			await _safe(() async {
				await _xmdsService.getSchedule();
				SocketEventBus.instance.emit(SocketEvent.scheduleActivated, data);
			});
		});
	}

	void _onSchedulePaused() {
		_socketService.on('schedule:paused', (data) async {
			AppLogger.socket('schedule:paused received');
			await _safe(() async {
				await _xmdsService.getSchedule();
				SocketEventBus.instance.emit(SocketEvent.schedulePaused, data);
			});
		});
	}

	Future<ScreenStatusData?> refreshScreenStatus() async {
		final hardwareKey = await StorageService.instance.loadHardwareKey();
		if (hardwareKey == null || hardwareKey.isEmpty) return null;

		final status = await _screenService.getStatus(hardwareKey);
		await StorageService.instance.saveRegistrationStatus(status.status);
		if (status.isApprovedOrActive) {
			await StorageService.instance.setApproved(true);
		}
		return status;
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
