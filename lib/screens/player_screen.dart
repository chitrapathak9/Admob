import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_config.dart';
import '../models/play_item.dart';
import '../models/player_manifest.dart';
import '../services/download_service.dart';
import '../services/heartbeat_service.dart';
import '../services/impression_frequency_service.dart';
import '../services/impression_ping_service.dart';
import '../services/player_service.dart';
import '../services/revenue_campaign_service.dart';
import '../services/screenshot_service.dart';
import '../services/socket_service.dart';
import '../services/storage_cleanup_service.dart';
import '../services/storage_service.dart';
import '../services/xmr_service.dart';
import '../utils/app_logger.dart';
import '../widgets/image_slide.dart';
import '../widgets/theadbook_logo.dart';
import '../widgets/video_slide.dart';
import 'setup_screen.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  static const Color _loadingOrange = Color(0xFFF97316);

  List<PlayItem> _playlist = [];
  int _currentIndex = 0;
  Timer? _retryTimer;
  Timer? _noContentTimer;
  bool _noContent = false;
  bool _collecting = false;
  int _slideKey = 0;
  String _manifestHash = '';
  int _mediaTotal = 0;
  int _mediaReady = 0;

  bool _isLoading = true;
  String _loadingMessage = 'Connecting to server...';
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _registerSocketListeners();
    _bootstrap();
  }

  void _registerSocketListeners() {
    final bus = SocketEventBus.instance;
    bus.on(SocketEvent.syncNow, _handleSocketContentChange);
    bus.on(SocketEvent.contentUpdated, _handleSocketContentChange);
    bus.on(SocketEvent.scheduleActivated, _handleSocketScheduleChange);
    bus.on(SocketEvent.schedulePaused, _handleSocketScheduleChange);
    bus.on(SocketEvent.reconnected, _handleSocketContentChange);
    bus.on(SocketEvent.deviceNotRegistered, _handleDeviceNotRegistered);
  }

  void _handleDeviceNotRegistered(dynamic _) {
    if (!mounted) return;
    unawaited(_goToConnectScreen());
  }

  void _handleSocketContentChange(dynamic _) {
    if (!mounted) return;
    _refreshManifest();
  }

  void _handleSocketScheduleChange(dynamic _) {
    if (!mounted) return;
    _refreshManifest();
  }

  Future<void> _bootstrap() async {
    StorageCleanupService.instance.start();
    unawaited(ImpressionFrequencyService.instance.init());
    unawaited(ImpressionPingService.instance.init());
    await _initPlayer();
    if (!mounted) return;

    await _connectXmr();
    _startHeartbeat();
  }

  Future<bool> _initPlayer() async {
    debugPrint('[Player] Starting init...');
    if (!mounted) return false;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _noContent = false;
      _loadingMessage = 'Loading content manifest...';
    });

    _retryTimer?.cancel();

    try {
      final hardwareKey = await StorageService.instance
          .getOrCreateHardwareKey();
      final manifest = await PlayerService.instance.getManifest(hardwareKey);

      _manifestHash = manifest.manifestHash;
      _mediaTotal = manifest.media.length;
      await StorageService.instance.saveManifestHash(manifest.manifestHash);

      if (manifest.media.isEmpty) {
        debugPrint('[Player] Empty manifest — no content scheduled');
        if (!mounted) return false;
        _enterNoContentState();
        return false;
      }

      if (!mounted) return false;
      setState(() => _loadingMessage = 'Downloading media...');

      await DownloadService.instance.downloadManifestMedia(manifest.media);
      final playlist = await _buildPlaylistFromManifest(manifest);
      _mediaReady = playlist.length;

      // Layer 1 (threshold) checked here; content hasn't changed yet on first load.
      StorageCleanupService.instance.onManifestUpdated(manifest, contentChanged: false);

      if (playlist.isEmpty) {
        if (!mounted) return false;
        setState(() {
          _isLoading = false;
          _errorMessage = 'Could not prepare media for playback';
        });
        _startAutoRetry();
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
    } on PlayerApiException catch (e) {
      debugPrint('[Player] Manifest API error: ${e.code} — ${e.message}');
      if (!mounted) return false;
      if (e.isNotRegistered) {
        await _goToConnectScreen();
        return false;
      }
      if (_playlist.isNotEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
        return true;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = e.message;
      });
      _startAutoRetry();
      return false;
    } catch (e, st) {
      debugPrint('[Player] Error: $e');
      debugPrint('[Player] Stack: $st');
      if (!mounted) return false;
      if (_playlist.isNotEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
        return true;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
      _startAutoRetry();
      return false;
    }
  }

  Future<List<PlayItem>> _buildPlaylistFromManifest(
    PlayerManifest manifest,
  ) async {
    final sorted = [...manifest.media]
      ..sort((a, b) => a.order.compareTo(b.order));
    final items = <PlayItem>[];
    final eventId = (manifest.schedule?['eventId'] as num?)?.toInt() ?? 0;

    for (final media in sorted) {
      if (media.filename.isEmpty) continue;
      final path = await DownloadService.instance.getMediaLocalPath(
        media.filename,
      );
      if (!await File(path).exists()) continue;

      items.add(
        PlayItem(
          localPath: path,
          type: media.type,
          duration: media.duration,
          mediaId: media.mediaId.toString(),
          layoutId: media.layoutId.toString(),
          scheduleId: eventId,
          filename: media.filename,
          name: media.name,
          campaignId: media.campaignId,
          maxPerDay: media.maxPerDay,
          maxPerMonth: media.maxPerMonth,
          dailyCapPerScreen: media.dailyCapPerScreen,
        ),
      );
    }
    // Register updated frequency limits so shouldShow() stays current.
    ImpressionFrequencyService.instance.updateLimits(items);
    return items;
  }

  void _enterNoContentState() {
    _noContentTimer?.cancel();
    setState(() {
      _isLoading = false;
      _errorMessage = null;
      _noContent = true;
      _playlist = [];
    });
    _startNoContentPolling();
  }

  void _startNoContentPolling() {
    _noContentTimer?.cancel();
    _noContentTimer = Timer.periodic(
      const Duration(seconds: AppConfig.manifestRetrySeconds),
      (_) => _refreshManifest(silent: true),
    );
  }

  void _startAutoRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer.periodic(
      const Duration(seconds: AppConfig.manifestRetrySeconds),
      (_) {
        if (_errorMessage != null && mounted && !_isLoading) {
          debugPrint('[Player] Auto-retry...');
          _initPlayer().then((ok) {
            if (ok && mounted) _startHeartbeat();
          });
        }
      },
    );
  }

  Future<void> _onRetryTap() async {
    debugPrint('[Player] Manual retry');
    await _initPlayer();
    if (!mounted) return;
    if (_errorMessage == null && _playlist.isNotEmpty) {
      await _connectXmr();
      _startHeartbeat();
    }
  }

  Future<void> _connectXmr() async {
    final xmrUrl = await StorageService.instance.getXmrUrl();
    if (xmrUrl == null || xmrUrl.isEmpty) return;

    XmrService.instance.onCollectNow = () => _refreshManifest();
    XmrService.instance.onRevertToSchedule = () => _refreshManifest();
		XmrService.instance.onScreenshot = () {
			AppLogger.screenshotEvent('Step 1 — XMR screenshot action received');
			unawaited(ScreenshotService.instance.captureAndUpload());
		};
    await XmrService.instance.connect(xmrUrl);
  }

  void _startHeartbeat() {
    HeartbeatService.instance.start(
      playingNameProvider: _currentPlayingName,
      onRefresh: () => _refreshManifest(),
    );
  }

  String? _currentPlayingName() {
    if (_playlist.isEmpty) return null;
    return _playlist[_currentIndex % _playlist.length].displayName;
  }

  void _stopHeartbeat() {
    HeartbeatService.instance.stop();
  }

  Future<void> _refreshManifest({bool silent = false}) async {
    if (_collecting || _isLoading) return;
    _collecting = true;

    try {
      final hardwareKey = await StorageService.instance
          .getOrCreateHardwareKey();
      final manifest = await PlayerService.instance.getManifest(hardwareKey);
      final previousHash = _manifestHash.isNotEmpty
          ? _manifestHash
          : (await StorageService.instance.loadManifestHash()) ?? '';

      if (manifest.media.isEmpty) {
        if (_playlist.isEmpty && mounted) {
          _enterNoContentState();
        }
        return;
      }

      if (manifest.manifestHash == previousHash && _playlist.isNotEmpty) {
        return;
      }

      await DownloadService.instance.downloadManifestMedia(manifest.media);
      // Layer 1 (threshold) + Layer 2 (campaign end) — contentChanged when hash differs.
      StorageCleanupService.instance.onManifestUpdated(
        manifest,
        contentChanged: manifest.manifestHash != previousHash,
      );
      final newPlaylist = await _buildPlaylistFromManifest(manifest);

      _manifestHash = manifest.manifestHash;
      _mediaTotal = manifest.media.length;
      _mediaReady = newPlaylist.length;
      await StorageService.instance.saveManifestHash(manifest.manifestHash);

      if (!mounted || newPlaylist.isEmpty) return;

      if (_noContent) {
        setState(() => _noContent = false);
        _noContentTimer?.cancel();
      }

      if (!_playlistEquals(_playlist, newPlaylist)) {
        setState(() {
          _playlist = newPlaylist;
          _currentIndex = 0;
          _slideKey++;
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } on PlayerApiException catch (e) {
      debugPrint('[Player] Manifest refresh: ${e.code}');
      if (e.isNotRegistered && mounted) {
        await _goToConnectScreen();
        return;
      }
      if (!silent && _playlist.isEmpty && mounted) {
        setState(() => _errorMessage = e.message);
      }
    } catch (e) {
      debugPrint('[Player] Manifest refresh failed: $e');
    } finally {
      _collecting = false;
    }
  }

  Widget _buildSocketConnectionIndicator() {
    return StreamBuilder<bool>(
      stream: SocketService.instance.connectionStream,
      initialData: SocketService.instance.isConnected,
      builder: (context, snapshot) {
        final connected = snapshot.data ?? false;
        return Positioned(
          top: 8,
          right: 8,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: connected ? Colors.green : Colors.red,
            ),
          ),
        );
      },
    );
  }

  bool _playlistEquals(List<PlayItem> a, List<PlayItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onItemComplete(PlayItem item) {
    // Record impression and fire async ping — both are non-blocking.
    unawaited(ImpressionFrequencyService.instance.recordImpression(item));
    unawaited(ImpressionPingService.instance.ping(item));

    setState(() {
      _currentIndex = _nextAllowedIndex(_currentIndex + 1);
      _slideKey++;
    });
  }

  /// Returns the next playlist index that passes both frequency and prepaid
  /// guards. Falls back to the raw next index if every item is blocked
  /// (prevents an infinite loop — content still cycles).
  int _nextAllowedIndex(int from) {
    final len = _playlist.length;
    if (len == 0) return 0;
    for (var i = 0; i < len; i++) {
      final idx = (from + i) % len;
      final candidate = _playlist[idx];
      if (!ImpressionFrequencyService.instance.shouldShow(candidate)) continue;
      if (RevenueCampaignService.instance.isCampaignPaused(candidate.campaignId)) {
        continue;
      }
      return idx;
    }
    return from % len;
  }

  Future<void> _goToConnectScreen() async {
    _stopHeartbeat();
    _retryTimer?.cancel();
    _noContentTimer?.cancel();
    await XmrService.instance.dispose();

    await StorageService.instance.clearAll();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const SetupScreen()),
    );
  }

  @override
  void dispose() {
    final bus = SocketEventBus.instance;
    bus.off(SocketEvent.syncNow, _handleSocketContentChange);
    bus.off(SocketEvent.contentUpdated, _handleSocketContentChange);
    bus.off(SocketEvent.scheduleActivated, _handleSocketScheduleChange);
    bus.off(SocketEvent.schedulePaused, _handleSocketScheduleChange);
    bus.off(SocketEvent.reconnected, _handleSocketContentChange);
    bus.off(SocketEvent.deviceNotRegistered, _handleDeviceNotRegistered);
    _stopHeartbeat();
    _retryTimer?.cancel();
    _noContentTimer?.cancel();
    XmrService.instance.dispose();
    StorageCleanupService.instance.stop();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(_goToConnectScreen());
      },
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
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
              Text(
                'Will retry automatically in ${AppConfig.manifestRetrySeconds} seconds',
                style: const TextStyle(color: Colors.white24, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
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
              Text(
                'Checking every ${AppConfig.manifestRetrySeconds} seconds…',
                style: const TextStyle(color: Colors.white38, fontSize: 14),
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
                _mediaTotal == 0
                    ? 'Waiting for content from server…'
                    : '$_mediaReady of $_mediaTotal media files ready',
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
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

  static const _videoExtensions = {'.mp4', '.mov', '.mkv', '.webm', '.m4v'};

  bool _isVideo(PlayItem item) {
    if (item.type == 'video') return true;
    final lower = item.filename.toLowerCase();
    return _videoExtensions.any(lower.endsWith);
  }

  Widget _buildPlayerUi() {
    final item = _playlist[_currentIndex % _playlist.length];

    return Scaffold(
      backgroundColor: AppConfig.background,
      body: Stack(
        children: [
          KeyedSubtree(
            key: ValueKey<int>(_slideKey),
            child: _isVideo(item)
                ? VideoSlide(
                    localPath: item.localPath,
                    duration: item.duration,
                    onComplete: () => _onItemComplete(item),
                  )
                : ImageSlide(
                    localPath: item.localPath,
                    duration: item.duration,
                    onComplete: () => _onItemComplete(item),
                  ),
          ),
          if (kDebugMode) _buildSocketConnectionIndicator(),
        ],
      ),
    );
  }
}
