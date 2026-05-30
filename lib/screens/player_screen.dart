import 'dart:async';
import 'dart:math' show min;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_config.dart';
import '../models/download_progress.dart';
import '../models/play_item.dart';
import '../models/required_file.dart';
import '../models/schedule_item.dart';
import '../services/download_service.dart';
import '../services/storage_service.dart';
import '../services/xlf_parser.dart';
import '../services/xmds_service.dart';
import '../services/xmr_service.dart';
import '../widgets/image_slide.dart';
import '../widgets/theadbook_logo.dart';
import '../widgets/video_slide.dart';

class PlayerScreen extends StatefulWidget {
	const PlayerScreen({super.key});

	@override
	State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
	static const Color _loadingOrange = Color(0xFFF97316);

	List<PlayItem> _playlist = [];
	int _currentIndex = 0;
	Timer? _heartbeatTimer;
	Timer? _scheduleTimer;
	Timer? _retryTimer;
	Timer? _playlistRetryTimer;
	Timer? _noContentTimer;
	String _layoutId = '0';
	bool _noContent = false;
	DownloadProgress _downloadProgress = const DownloadProgress();
	String _lastMediaId = '0';
	bool _collecting = false;
	int _slideKey = 0;

	bool _isLoading = true;
	String _loadingMessage = 'Connecting to server...';
	String? _errorMessage;

	String rawScheduleXml = '';
	String rawRequiredFilesXml = '';
	List<RequiredFile> _lastRequiredFiles = [];
	List<ScheduleItem> _lastScheduleItems = [];
	List<PlayItem> _lastPlaylistAttempt = [];

	final Dio _dio = Dio(BaseOptions(
		connectTimeout: const Duration(seconds: 60),
		receiveTimeout: const Duration(seconds: 120),
		headers: {'Content-Type': 'text/xml; charset=utf-8'},
	));

	@override
	void initState() {
		super.initState();
		SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
		WakelockPlus.enable();
		_bootstrap();
	}

	Future<void> _bootstrap() async {
		final ok = await _initPlayer();
		if (!ok || !mounted) return;

		await _connectXmr();
		_startHeartbeat();
		_startScheduleTimer();
	}

	Future<bool> _initPlayer() async {
		debugPrint('[Player] Starting init...');
		if (!mounted) return false;

		setState(() {
			_isLoading = true;
			_errorMessage = null;
			_noContent = false;
			_loadingMessage = 'Connecting to server...';
		});

		_retryTimer?.cancel();

		List<RequiredFile> required = [];
		List<ScheduleItem> schedule = [];
		String defaultLayout = '';
		List<PlayItem> playlist = [];

		try {
			final serverKey = await _serverKey();
			final hardwareKey = await _hardwareKey();

			if (!mounted) return false;
			setState(() => _loadingMessage = 'Loading schedule...');
			debugPrint('[Player] Loading schedule...');

			final scheduleResponse = await _postXmdsRaw('Schedule', '''<tns:Schedule>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
    </tns:Schedule>''');
			rawScheduleXml = scheduleResponse.data.toString();
			debugPrint('[Player] Raw Schedule: ${rawScheduleXml.length} chars');

			final scheduleResult = await XmdsService.instance.getScheduleWithDefault();
			defaultLayout = scheduleResult.defaultLayoutId;
			final allSchedule = scheduleResult.schedule;
			debugPrint('[Player] Schedule items (raw): ${allSchedule.length}');
			debugPrint('[Player] Default layout: $defaultLayout');

			if (!mounted) return false;
			setState(() => _loadingMessage = 'Fetching required files...');
			debugPrint('[Player] Fetching required files...');

			final requiredFilesResponse = await _postXmdsRaw('RequiredFiles', '''<tns:RequiredFiles>
      <serverKey>$serverKey</serverKey>
      <hardwareKey>$hardwareKey</hardwareKey>
    </tns:RequiredFiles>''');
			rawRequiredFilesXml = requiredFilesResponse.data.toString();
			debugPrint('[Player] Raw RequiredFiles: ${rawRequiredFilesXml.length} chars');

			required = await XmdsService.instance.getRequiredFiles();
			_lastRequiredFiles = required;
			debugPrint('[Player] RequiredFiles response: ${required.length} files');

			schedule = ScheduleItem.filterActiveNow(ScheduleItem.withoutDefaultFallback(allSchedule));
			if (schedule.isEmpty) {
				final fromManifest = RequiredFile.layoutIdsFromFiles(required);
				if (fromManifest.isNotEmpty) {
					schedule = ScheduleItem.fromLayoutIds(fromManifest);
					debugPrint('[Player] Schedules from RequiredFiles layouts: $fromManifest');
				}
			}

			if (schedule.isEmpty && !DownloadService.hasPlayableManifestContent(required)) {
				debugPrint('[Player] No scheduled content — showing no content screen');
				_lastScheduleItems = [];
				if (!mounted) return false;
				_enterNoContentState();
				return false;
			}

			_lastScheduleItems = schedule;
			debugPrint('[Player] Active schedule items: ${schedule.length}');

			if (!mounted) return false;
			setState(() => _loadingMessage = 'Downloading media...');
			debugPrint('[Player] Downloading media...');

			final missing = await DownloadService.instance.filterMissing(required);
			debugPrint('[Player] Missing files: ${missing.length}');
			await DownloadService.instance.downloadAllMissing(missing);

			if (!mounted) return false;
			setState(() => _loadingMessage = 'Downloading layout content...');
			required = await DownloadService.instance.syncContentForSchedule(
				schedule: schedule,
				defaultLayoutId: defaultLayout,
				knownRequired: required,
			);
			_lastRequiredFiles = required;

			final mediaOnDisk = <RequiredFile>[];
			for (final f in required) {
				if (DownloadService.shouldSkipPlaybackFile(f)) continue;
				if (!RequiredFile.isPlayableMediaFilename(f.saveAs)) continue;
				if (await DownloadService.instance.fileExists(f.saveAs, f.md5)) {
					mediaOnDisk.add(f);
				}
			}
			if (mediaOnDisk.isNotEmpty) {
				try {
					await XmdsService.instance.mediaInventory(mediaOnDisk);
					debugPrint('[Player] MediaInventory reported: ${mediaOnDisk.length} files');
				} catch (e) {
					debugPrint('[Player] MediaInventory failed (continuing): $e');
				}
			}

			if (!mounted) return false;
			setState(() => _loadingMessage = 'Preparing playback...');

			final build = await XlfParser.instance.buildPlaylistFromSchedule(
				schedule: schedule,
				defaultLayoutId: defaultLayout,
				requiredFiles: required,
			);
			playlist = build.playlist;
			_layoutId = build.layoutId;
			_downloadProgress = build.downloadProgress;
			_lastPlaylistAttempt = playlist;
			debugPrint('[Player] Playlist built: ${playlist.length} items');

			if (build.layoutId.isNotEmpty) {
				await StorageService.instance.setCurrentLayoutId(build.layoutId);
			}

			if (playlist.isEmpty) {
				if (!mounted) return false;
				setState(() {
					_isLoading = false;
					_errorMessage = null;
					_noContent = false;
				});
				_startPlaylistRetry(required, schedule, defaultLayout);
				return false;
			}

			if (!mounted) return false;
			setState(() {
				_playlist = playlist;
				_currentIndex = 0;
				_slideKey++;
				_isLoading = false;
				_errorMessage = null;
				_noContent = false;
			});
			debugPrint('[Player] Init complete — ${_playlist.length} items ready');
			return true;
		} catch (e, st) {
			debugPrint('[Player] Error: ${e.toString()}');
			debugPrint('[Player] Stack: $st');
			if (!mounted) return false;
			setState(() {
				_isLoading = false;
				_errorMessage = e.toString().replaceFirst('Exception: ', '');
			});
			_startAutoRetry();
			return false;
		}
	}

	Future<String> _serverKey() async {
		final key = await StorageService.instance.getCmsKey();
		if (key == null || key.isEmpty) throw Exception('CMS key not configured');
		return key;
	}

	Future<String> _hardwareKey() async {
		return StorageService.instance.getOrCreateHardwareKey();
	}

	Future<Response<String>> _postXmdsRaw(String method, String methodBody) async {
		final xmdsUrl = await StorageService.instance.getXmdsUrl();
		final base = (xmdsUrl == null || xmdsUrl.isEmpty)
			? '${AppConfig.baseUrl}/xmds.php'
			: xmdsUrl;
		final endpoint = '$base?v=${AppConfig.xmdsVersion}&method=$method';
		final envelope = '''<?xml version="1.0" encoding="UTF-8"?>
<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:tns="urn:xmds">
  <soap:Body>
    $methodBody
  </soap:Body>
</soap:Envelope>''';

		return _dio.post<String>(
			endpoint,
			data: envelope,
			options: Options(
				headers: {'SOAPAction': 'urn:xmds#$method'},
				responseType: ResponseType.plain,
				validateStatus: (_) => true,
			),
		);
	}

	static const TextStyle _debugTextStyle = TextStyle(color: Colors.white, fontSize: 10);

	Widget _buildDebugPanel() {
		final rfPreview = rawRequiredFilesXml.substring(0, min(500, rawRequiredFilesXml.length));
		final schedPreview = rawScheduleXml.substring(0, min(500, rawScheduleXml.length));

		return Column(
			crossAxisAlignment: CrossAxisAlignment.start,
			children: [
				const SizedBox(height: 24),
				Text('RequiredFiles count: ${_lastRequiredFiles.length}', style: _debugTextStyle),
				Text(
					'On disk: ${_downloadProgress.filesReady}/${_downloadProgress.filesTotal} '
					'(deps ${_downloadProgress.dependenciesReady}/${_downloadProgress.dependenciesTotal}, '
					'layouts ${_downloadProgress.layoutsReady}/${_downloadProgress.layoutsTotal}, '
					'media ${_downloadProgress.campaignMediaReady}/${_downloadProgress.campaignMediaTotal})',
					style: _debugTextStyle,
				),
				Text('Schedule items: ${_lastScheduleItems.length}', style: _debugTextStyle),
				Text('Playlist items: ${_lastPlaylistAttempt.length}', style: _debugTextStyle),
				const SizedBox(height: 12),
				const Text('Raw schedule XML (first 500 chars):', style: _debugTextStyle),
				Text(schedPreview.isEmpty ? '(empty)' : schedPreview, style: _debugTextStyle),
				const SizedBox(height: 8),
				const Text('Raw requiredFiles XML (first 500 chars):', style: _debugTextStyle),
				Text(rfPreview.isEmpty ? '(empty)' : rfPreview, style: _debugTextStyle),
			],
		);
	}

	void _enterNoContentState() {
		_playlistRetryTimer?.cancel();
		_noContentTimer?.cancel();
		setState(() {
			_isLoading = false;
			_errorMessage = null;
			_noContent = true;
			_playlist = [];
			_lastPlaylistAttempt = [];
		});
		_startNoContentPolling();
	}

	void _startNoContentPolling() {
		_noContentTimer?.cancel();
		_noContentTimer = Timer.periodic(const Duration(seconds: 60), (_) => _pollScheduleForContent());
	}

	Future<void> _pollScheduleForContent() async {
		if (!mounted || !_noContent) return;
		debugPrint('[Player] No-content poll — checking schedule...');
		try {
			final scheduleResult = await XmdsService.instance.getScheduleWithDefault();
			final required = await XmdsService.instance.getRequiredFiles();
			_lastRequiredFiles = required;

			var scheduled = ScheduleItem.filterActiveNow(
				ScheduleItem.withoutDefaultFallback(scheduleResult.schedule),
			);
			if (scheduled.isEmpty) {
				final fromManifest = RequiredFile.layoutIdsFromFiles(required);
				if (fromManifest.isNotEmpty) {
					scheduled = ScheduleItem.fromLayoutIds(fromManifest);
				}
			}
			_lastScheduleItems = scheduled;

			if (scheduled.isEmpty && !DownloadService.hasPlayableManifestContent(required)) {
				return;
			}

			debugPrint('[Player] Content available — restarting init');
			_noContentTimer?.cancel();
			if (!mounted) return;
			setState(() => _noContent = false);
			final ok = await _initPlayer();
			if (!mounted || !ok) return;
			await _connectXmr();
			_startHeartbeat();
			_startScheduleTimer();
		} catch (e) {
			debugPrint('[Player] No-content schedule poll failed: $e');
		}
	}

	void _startPlaylistRetry(
		List<RequiredFile> required,
		List<ScheduleItem> schedule,
		String defaultLayout,
	) {
		_playlistRetryTimer?.cancel();
		_playlistRetryTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
			if (!mounted || _playlist.isNotEmpty) return;
			debugPrint('[XLF] Auto-retry building playlist...');
			var syncedRequired = required;
			try {
				syncedRequired = await DownloadService.instance.syncContentForSchedule(
					schedule: schedule,
					defaultLayoutId: defaultLayout,
					knownRequired: required,
				);
			} catch (e) {
				debugPrint('[XLF] Auto-retry sync failed: $e');
			}
			final build = await XlfParser.instance.buildPlaylistFromSchedule(
				schedule: schedule,
				defaultLayoutId: defaultLayout,
				requiredFiles: syncedRequired,
			);
			if (!mounted) return;
			setState(() {
				_downloadProgress = build.downloadProgress;
				_lastPlaylistAttempt = build.playlist;
			});
			if (build.playlist.isNotEmpty) {
				_playlistRetryTimer?.cancel();
				setState(() {
					_playlist = build.playlist;
					_layoutId = build.layoutId;
					_currentIndex = 0;
					_slideKey++;
					_isLoading = false;
					_errorMessage = null;
				});
				_startHeartbeat();
				_startScheduleTimer();
			}
		});
	}

	void _startAutoRetry() {
		_retryTimer?.cancel();
		_retryTimer = Timer.periodic(const Duration(seconds: 60), (_) {
			if (_errorMessage != null && mounted && !_isLoading) {
				debugPrint('[Player] Auto-retry...');
				_initPlayer();
			}
		});
	}

	Future<void> _onRetryTap() async {
		debugPrint('[Player] Manual retry');
		await _initPlayer();
		if (!mounted) return;
		if (_errorMessage == null && _playlist.isNotEmpty) {
			await _connectXmr();
			_startHeartbeat();
			_startScheduleTimer();
		}
	}

	Future<void> _connectXmr() async {
		final xmrUrl = await StorageService.instance.getXmrUrl();
		if (xmrUrl == null || xmrUrl.isEmpty) return;

		XmrService.instance.onCollectNow = () => _runCollectionCycle();
		XmrService.instance.onRevertToSchedule = () => _runCollectionCycle();
		await XmrService.instance.connect(xmrUrl);
	}

	void _startHeartbeat() {
		_heartbeatTimer?.cancel();
		_heartbeatTimer = Timer.periodic(
			const Duration(seconds: AppConfig.heartbeatIntervalSeconds),
			(_) => _sendHeartbeat(),
		);
		_sendHeartbeat();
	}

	void _startScheduleTimer() async {
		final interval = await StorageService.instance.getCollectionInterval();
		_scheduleTimer?.cancel();
		_scheduleTimer = Timer.periodic(Duration(seconds: interval), (_) => _runCollectionCycle());
	}

	Future<void> _sendHeartbeat() async {
		try {
			final freeMB = await DownloadService.instance.getFreeSpaceMB();
			await XmdsService.instance.notifyStatus(
				layoutId: _layoutId,
				freeMB: freeMB,
				lastMediaId: _lastMediaId,
			);
		} catch (_) {}
	}

	Future<void> _runCollectionCycle() async {
		if (_collecting || _isLoading) return;
		_collecting = true;
		try {
			debugPrint('[Player] Background collection cycle...');
			var required = await XmdsService.instance.getRequiredFiles();
			final missing = await DownloadService.instance.filterMissing(required);
			await DownloadService.instance.downloadAllMissing(missing);

			final scheduleResult = await XmdsService.instance.getScheduleWithDefault();
			required = await DownloadService.instance.syncContentForSchedule(
				schedule: scheduleResult.schedule,
				defaultLayoutId: scheduleResult.defaultLayoutId,
				knownRequired: required,
			);

			final mediaOnDisk = <RequiredFile>[];
			for (final f in required) {
				if (DownloadService.shouldSkipPlaybackFile(f)) continue;
				if (!RequiredFile.isPlayableMediaFilename(f.saveAs)) continue;
				if (await DownloadService.instance.fileExists(f.saveAs, f.md5)) {
					mediaOnDisk.add(f);
				}
			}
			if (mediaOnDisk.isNotEmpty) {
				try {
					await XmdsService.instance.mediaInventory(mediaOnDisk);
				} catch (_) {}
			}

			final build = await XlfParser.instance.buildPlaylistFromSchedule(
				schedule: scheduleResult.schedule,
				defaultLayoutId: scheduleResult.defaultLayoutId,
				requiredFiles: required,
			);

			if (build.layoutId.isNotEmpty) _layoutId = build.layoutId;
			if (!mounted || build.playlist.isEmpty) return;
			if (!_playlistEquals(_playlist, build.playlist)) {
				setState(() {
					_playlist = build.playlist;
					_currentIndex = 0;
					_slideKey++;
				});
			}
		} catch (e) {
			debugPrint('[Player] Background collection failed: $e');
		} finally {
			_collecting = false;
		}
	}

	bool _playlistEquals(List<PlayItem> a, List<PlayItem> b) {
		if (a.length != b.length) return false;
		for (var i = 0; i < a.length; i++) {
			if (a[i] != b[i]) return false;
		}
		return true;
	}

	void _onItemComplete(PlayItem item) {
		_submitStats(item);
		_lastMediaId = item.mediaId.isNotEmpty ? item.mediaId : _lastMediaId;
		setState(() {
			_currentIndex = (_currentIndex + 1) % (_playlist.isEmpty ? 1 : _playlist.length);
			_slideKey++;
		});
	}

	Future<void> _submitStats(PlayItem item) async {
		try {
			final now = DateTime.now();
			final end = now;
			final start = now.subtract(Duration(seconds: item.duration));
			final fmt = _formatDateTime;
			final statXml = '''<stats>
  <stat type="media"
        fromdt="${fmt(start)}"
        todt="${fmt(end)}"
        scheduleid="${item.scheduleId}"
        layoutid="${item.layoutId}"
        mediaid="${item.mediaId}" />
</stats>''';
			await XmdsService.instance.submitStats(statXml: statXml);
		} catch (_) {}
	}

	String _formatDateTime(DateTime dt) {
		final y = dt.year.toString().padLeft(4, '0');
		final m = dt.month.toString().padLeft(2, '0');
		final d = dt.day.toString().padLeft(2, '0');
		final h = dt.hour.toString().padLeft(2, '0');
		final min = dt.minute.toString().padLeft(2, '0');
		final s = dt.second.toString().padLeft(2, '0');
		return '$y-$m-$d $h:$min:$s';
	}

	@override
	void dispose() {
		_heartbeatTimer?.cancel();
		_scheduleTimer?.cancel();
		_retryTimer?.cancel();
		_playlistRetryTimer?.cancel();
		_noContentTimer?.cancel();
		XmrService.instance.dispose();
		WakelockPlus.disable();
		SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		if (_isLoading) {
			return _buildLoadingUi();
		}
		if (_errorMessage != null) {
			return _buildErrorUi();
		}
		if (_noContent) {
			return _buildNoContentUi();
		}
		if (_playlist.isEmpty) {
			return _buildDownloadingUi();
		}
		return _buildPlayerUi();
	}

	Widget _buildLoadingUi() {
		return Scaffold(
			backgroundColor: AppConfig.background,
			body: Center(
				child: Padding(
					padding: const EdgeInsets.all(32),
					child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						children: [
							const TheadbookLogo(height: 100),
							const SizedBox(height: 40),
							const CircularProgressIndicator(color: _loadingOrange),
							const SizedBox(height: 24),
							Text(
								_loadingMessage,
								style: const TextStyle(color: Colors.white70, fontSize: 16),
								textAlign: TextAlign.center,
							),
						],
					),
				),
			),
		);
	}

	Widget _buildErrorUi() {
		return Scaffold(
			backgroundColor: AppConfig.background,
			body: SafeArea(
				child: SingleChildScrollView(
					padding: const EdgeInsets.all(16),
					child: Column(
						crossAxisAlignment: CrossAxisAlignment.stretch,
						children: [
							const Text(
								'Could not load content',
								style: TextStyle(color: Colors.white, fontSize: 22),
								textAlign: TextAlign.center,
							),
							const SizedBox(height: 16),
							Text(
								_errorMessage ?? '',
								style: const TextStyle(color: Colors.white38, fontSize: 14),
								textAlign: TextAlign.center,
							),
							_buildDebugPanel(),
							const SizedBox(height: 24),
							ElevatedButton(
								onPressed: _onRetryTap,
								style: ElevatedButton.styleFrom(
									backgroundColor: _loadingOrange,
									foregroundColor: Colors.black,
								),
								child: const Text('Retry', style: TextStyle(fontSize: 18)),
							),
							const SizedBox(height: 16),
							const Text(
								'Will retry automatically in 60 seconds',
								style: TextStyle(color: Colors.white24, fontSize: 12),
								textAlign: TextAlign.center,
							),
						],
					),
				),
			),
		);
	}

	String _downloadingHeadline() {
		final p = _downloadProgress;
		if (p.filesTotal == 0) return 'Waiting for content from server…';
		return '${p.filesReady} of ${p.filesTotal} required files on device';
	}

	String _downloadingDetail() {
		final p = _downloadProgress;
		final scheduleCount = _lastScheduleItems.length;
		final playlistCount = _lastPlaylistAttempt.length;
		final parts = <String>[];

		if (p.dependenciesTotal > 0) {
			parts.add('Dependencies: ${p.dependenciesReady}/${p.dependenciesTotal}');
		}
		if (p.layoutsTotal > 0) {
			parts.add('Layouts: ${p.layoutsReady}/${p.layoutsTotal}');
		} else if (scheduleCount > 0) {
			parts.add('Layouts: waiting for ${scheduleCount} scheduled');
		}
		if (p.campaignMediaTotal > 0) {
			parts.add('Campaign media: ${p.campaignMediaReady}/${p.campaignMediaTotal}');
		}
		parts.add('Playlist: $playlistCount items');

		if (scheduleCount == 0) {
			return '${parts.join(' · ')}\nNo campaigns in the current schedule window.';
		}
		if (playlistCount == 0 && p.allRequiredOnDisk) {
			return '${parts.join(' · ')}\nFiles are ready — waiting for layout/schedule sync.';
		}
		return parts.join(' · ');
	}

	Widget _buildNoContentUi() {
		return Scaffold(
			backgroundColor: AppConfig.background,
			body: SafeArea(
				child: Padding(
					padding: const EdgeInsets.all(32),
					child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						crossAxisAlignment: CrossAxisAlignment.stretch,
						children: [
							const Center(child: TheadbookLogo(height: 100)),
							const SizedBox(height: 40),
							const Text(
								'No content scheduled',
								style: TextStyle(color: Colors.white, fontSize: 22),
								textAlign: TextAlign.center,
							),
							const SizedBox(height: 16),
							const Text(
								'Content will appear automatically when scheduled',
								style: TextStyle(color: Colors.white54, fontSize: 16),
								textAlign: TextAlign.center,
							),
							const SizedBox(height: 24),
							const Text(
								'Checking every 60 seconds…',
								style: TextStyle(color: Colors.white38, fontSize: 14),
								textAlign: TextAlign.center,
							),
						],
					),
				),
			),
		);
	}

	Widget _buildDownloadingUi() {
		return Scaffold(
			backgroundColor: AppConfig.background,
			body: SafeArea(
				child: SingleChildScrollView(
					padding: const EdgeInsets.all(16),
					child: Column(
						crossAxisAlignment: CrossAxisAlignment.stretch,
						children: [
							const Center(child: TheadbookLogo(height: 80)),
							const SizedBox(height: 32),
							const CircularProgressIndicator(color: _loadingOrange),
							const SizedBox(height: 24),
							Text(
								_downloadingHeadline(),
								style: const TextStyle(color: Colors.white, fontSize: 18),
								textAlign: TextAlign.center,
							),
							const SizedBox(height: 12),
							Text(
								_downloadingDetail(),
								style: const TextStyle(color: Colors.white38, fontSize: 14),
								textAlign: TextAlign.center,
							),
							const SizedBox(height: 8),
							const Text(
								'Playlist rebuilds automatically every 30 seconds',
								style: TextStyle(color: Colors.white24, fontSize: 12),
								textAlign: TextAlign.center,
							),
							_buildDebugPanel(),
							const SizedBox(height: 24),
							ElevatedButton(
								onPressed: _onRetryTap,
								style: ElevatedButton.styleFrom(
									backgroundColor: _loadingOrange,
									foregroundColor: Colors.black,
								),
								child: const Text('Retry now', style: TextStyle(fontSize: 18)),
							),
						],
					),
				),
			),
		);
	}

	Widget _buildPlayerUi() {
		final item = _playlist[_currentIndex % _playlist.length];

		return Scaffold(
			backgroundColor: AppConfig.background,
			body: KeyedSubtree(
				key: ValueKey<int>(_slideKey),
				child: item.type == 'video'
					? VideoSlide(
						localPath: item.localPath,
						onComplete: () => _onItemComplete(item),
					)
					: ImageSlide(
						localPath: item.localPath,
						duration: item.duration,
						onComplete: () => _onItemComplete(item),
					),
			),
		);
	}
}
