import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_constants.dart';
import '../models/play_item.dart';
import '../services/collection_service.dart';
import '../services/config_service.dart';
import '../services/diagnostics_service.dart';
import '../services/download_service.dart';
import '../services/storage_service.dart';
import '../services/xmds_service.dart';
import '../services/xmr_service.dart';
import '../utils/device_name.dart';
import 'logger.dart';
import 'state_machine.dart';

/// The brain of the player (Phase F2.6).
///
/// Owns the state machine and ALL timers; coordinates every service. Screens are
/// dumb and only read from this controller — they never call services directly.
class PlayerController extends ChangeNotifier {
  PlayerController();

  // ── State ───────────────────────────────────────────────────────────────────
  PlayerState _state = PlayerState.initializing;
  PlayerState get currentState => _state;
  UiScreen get uiScreen => _state.uiScreen;

  String _hardwareKey = '';
  String get hardwareKey => _hardwareKey;

  String _displayName = '';
  String get displayName => _displayName;

  bool _busy = false;
  bool get isBusy => _busy;

  String? _errorMessage;
  String? get errorMessage => _errorMessage;

  int _errorBackoffSeconds = AppConstants.errorBackoffSeconds;
  int _errorRetryCountdown = 0;
  int get errorRetryCountdown => _errorRetryCountdown;

  int _errorCount = 0;
  String _currentLayoutId = '0';

  // ── Playlist ────────────────────────────────────────────────────────────────
  List<PlayItem> _activePlaylist = [];
  List<PlayItem>? _pendingPlaylist;
  int _currentIndex = 0;

  int _collectionInterval = AppConstants.scheduleRefreshSeconds;

  // ── Timers ──────────────────────────────────────────────────────────────────
  Timer? _collectionTimer;
  Timer? _heartbeatTimer;
  Timer? _statusPollTimer;
  Timer? _errorTimer;

  // ── UI getters ──────────────────────────────────────────────────────────────
  PlayItem? get currentItem {
    if (_activePlaylist.isEmpty) return null;
    final i = _currentIndex.clamp(0, _activePlaylist.length - 1);
    return _activePlaylist[i];
  }

  int get playlistLength => _activePlaylist.length;
  int get currentIndex => _currentIndex;
  bool get isPlaying => _state == PlayerState.playing && _activePlaylist.isNotEmpty;

  // ── Transition (validated + logged) ─────────────────────────────────────────
  void transition(PlayerState next, {String? reason}) {
    if (next == _state) return;
    final allowed = _state.canTransitionTo(next);
    PlayerLogger.log('STATE', '${_state.label} → ${next.label}', data: {
      'reason': reason ?? '',
      if (!allowed) 'note': 'transition not in allowed set (forced for resilience)',
    });
    _state = next;
    notifyListeners();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════

  /// Called once on startup (from the splash screen).
  Future<void> initialize() async {
    PlayerLogger.log('INIT', 'Player initialize');
    try {
      await WakelockPlus.enable();
    } catch (_) {/* non-fatal on platforms without wakelock */}

    _hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
    _displayName = await StorageService.instance.loadDisplayName() ?? await defaultDisplayName();
    _collectionInterval = await StorageService.instance.getCollectionInterval();

    // Wire XMR push → immediate collection
    XmrService.instance.onCollectNow = _onCollectNow;
    XmrService.instance.onRevertToSchedule = _onCollectNow;

    final hasConfig = await StorageService.instance.hasConfig();
    if (!hasConfig) {
      PlayerLogger.log('INIT', 'No config found → CONFIGURING (setup)');
      transition(PlayerState.configuring, reason: 'no stored config');
      return;
    }

    // Connect XMR from stored URL
    final xmrUrl = await StorageService.instance.getXmrUrl();
    if (xmrUrl != null && xmrUrl.isNotEmpty) {
      unawaited(XmrService.instance.connect(xmrUrl));
    }

    PlayerLogger.log('INIT', 'Config present → REGISTERING');
    transition(PlayerState.registering, reason: 'cached config');
    await _registerAndRoute();
  }

  /// Called from the setup screen [Connect] button.
  Future<void> configure(String displayName, String cmsKey) async {
    _busy = true;
    _errorMessage = null;
    notifyListeners();

    try {
      PlayerLogger.log('CONFIG', 'fetchConfig start');
      final config = await ConfigService.instance.fetchConfig(); // persists to storage
      PlayerLogger.log('CONFIG', 'fetchConfig success', data: {'xmds': config.xmdsUrl});

      // Registration gate: if the operator typed a CMS key, it must match the
      // server's. Blank is allowed (uses the server key from /config).
      final typedKey = cmsKey.trim();
      if (typedKey.isNotEmpty && typedKey != config.cmsKey) {
        _busy = false;
        _errorMessage = 'CMS Key does not match server configuration';
        notifyListeners(); // stay on setup (configuring) screen, show error
        return;
      }
      if (typedKey.isNotEmpty) {
        await StorageService.instance.saveUserCmsKey(typedKey);
      }

      _displayName = displayName.trim().isEmpty ? await defaultDisplayName() : displayName.trim();
      await StorageService.instance.saveDisplayName(_displayName);

      _collectionInterval = config.collectionInterval;

      if (config.xmrUrl.isNotEmpty) {
        unawaited(XmrService.instance.connect(config.xmrUrl));
      }

      _busy = false;
      transition(PlayerState.registering, reason: 'config saved');
      await _registerAndRoute();
    } catch (e, st) {
      PlayerLogger.error('CONFIG', 'configure failed', e, st);
      _busy = false;
      _errorMessage = 'Setup failed: $e';
      transition(PlayerState.error, reason: 'configure failed');
      _scheduleErrorRetry();
    }
  }

  /// Register with XMDS then route to WAITING (pending) or SYNCING (approved).
  Future<void> _registerAndRoute() async {
    try {
      PlayerLogger.log('XMDS', 'calling RegisterDisplay', data: {'name': _displayName});
      final result = await XmdsService.instance.registerDisplay(_displayName);
      PlayerLogger.log('XMDS', 'RegisterDisplay code=${result.code}', data: {'msg': result.message});

      if (result.code == 201) {
        await StorageService.instance.setApproved(true);
        _errorCount = 0;
        transition(PlayerState.syncing, reason: 'approved (201)');
        _startTimers();
        await runCollectionCycle();
      } else {
        await StorageService.instance.setApproved(false);
        transition(PlayerState.waiting, reason: 'pending approval (${result.code})');
        _startStatusPoll();
      }
    } catch (e, st) {
      PlayerLogger.error('XMDS', 'RegisterDisplay failed', e, st);
      // Offline fallback: if previously approved, try to play cached content.
      final approved = await StorageService.instance.isApproved();
      if (approved) {
        PlayerLogger.log('PLAYER', 'Register failed but approved — trying cached content');
        transition(PlayerState.syncing, reason: 'offline cached attempt');
        _startTimers();
        await runCollectionCycle();
      } else {
        _errorMessage = 'Could not reach CMS: $e';
        transition(PlayerState.error, reason: 'register failed (not approved)');
        _scheduleErrorRetry();
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // WAITING — poll status every 15s
  // ══════════════════════════════════════════════════════════════════════════

  void _startStatusPoll() {
    _statusPollTimer?.cancel();
    PlayerLogger.log('PLAYER', 'Polling status every ${AppConstants.statusPollIntervalSeconds}s');
    _statusPollTimer = Timer.periodic(
      const Duration(seconds: AppConstants.statusPollIntervalSeconds),
      (_) => _pollStatus(),
    );
  }

  Future<void> _pollStatus() async {
    final status = await DiagnosticsService.instance.checkStatus(_hardwareKey);
    PlayerLogger.log('PLAYER', 'status=${status.status}');
    if (status.isActive) {
      await StorageService.instance.setApproved(true);
      _statusPollTimer?.cancel();
      _statusPollTimer = null;
      _errorCount = 0;
      transition(PlayerState.syncing, reason: 'admin approved');
      _startTimers();
      await runCollectionCycle();
    }
    // pending / not_found / error → keep polling
  }

  // ══════════════════════════════════════════════════════════════════════════
  // COLLECTION CYCLE — the core loop (ONLY place that drives XMDS sync)
  // ══════════════════════════════════════════════════════════════════════════

  void _startTimers() {
    _collectionTimer?.cancel();
    _heartbeatTimer?.cancel();

    final interval = _collectionInterval > 0 ? _collectionInterval : AppConstants.scheduleRefreshSeconds;
    _collectionTimer = Timer.periodic(Duration(seconds: interval), (_) => runCollectionCycle());
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: AppConstants.heartbeatSeconds),
      (_) => _sendHeartbeat(),
    );
  }

  bool _cycleRunning = false;

  Future<void> runCollectionCycle() async {
    if (_cycleRunning) {
      PlayerLogger.log('PLAYER', 'Collection cycle already running — skip');
      return;
    }
    _cycleRunning = true;
    PlayerLogger.log('PLAYER', 'Collection cycle start');
    try {
      final result = await CollectionService.instance.runCollectionCycle();
      final hasContent = result.playlist.isNotEmpty;
      final hasScheduledLayout = result.layoutId.isNotEmpty && result.layoutId != '0';

      PlayerLogger.log('PLAYER', 'Cycle result', data: {
        'items': result.playlist.length,
        'layoutId': result.layoutId,
      });

      if (hasContent) {
        _currentLayoutId = result.layoutId;
        _errorCount = 0;
        _updatePlaylist(result.playlist);
        if (_state != PlayerState.playing) {
          transition(PlayerState.playing, reason: 'playlist ${result.playlist.length} items');
        } else {
          notifyListeners();
        }
      } else if (hasScheduledLayout) {
        // Layout is scheduled but its media isn't on disk yet — keep syncing.
        PlayerLogger.log('PLAYER', 'Layout scheduled, media not ready — staying in sync');
        if (_state == PlayerState.noContent || _state == PlayerState.error) {
          transition(PlayerState.syncing, reason: 'content downloading');
        }
      } else {
        // Nothing scheduled at all.
        if (_state != PlayerState.noContent) {
          PlayerLogger.log('PLAYER', 'No scheduled layouts → NO_CONTENT');
          _activePlaylist = [];
          _pendingPlaylist = null;
          _currentIndex = 0;
          transition(PlayerState.noContent, reason: 'no scheduled content');
        }
      }
    } catch (e, st) {
      PlayerLogger.error('PLAYER', 'Collection cycle failed', e, st);
      // Keep playing cached content. Only escalate if we are not already playing.
      if (_state != PlayerState.playing) {
        _errorCount++;
        if (_errorCount > 3) {
          _errorMessage = 'Repeated sync failures: $e';
          transition(PlayerState.error, reason: 'collection failed x$_errorCount');
          _scheduleErrorRetry();
        }
      }
    } finally {
      _cycleRunning = false;
    }
  }

  // ── Playlist management (graceful swap) ─────────────────────────────────────
  void _updatePlaylist(List<PlayItem> next) {
    if (_state != PlayerState.playing || _activePlaylist.isEmpty) {
      _activePlaylist = next;
      _pendingPlaylist = null;
      _currentIndex = 0;
      return;
    }
    // Currently playing — swap at the end of the current item, only if changed.
    if (!_samePlaylist(_activePlaylist, next)) {
      _pendingPlaylist = next;
      PlayerLogger.log('PLAYER', 'Playlist changed — will swap after current item');
    }
  }

  /// Called by the player screen when an image duration expires or a video ends.
  void onItemComplete() {
    final completed = currentItem;
    if (completed != null) unawaited(_submitStats(completed));

    if (_pendingPlaylist != null) {
      _activePlaylist = _pendingPlaylist!;
      _pendingPlaylist = null;
      _currentIndex = 0;
    } else if (_activePlaylist.isNotEmpty) {
      _currentIndex = (_currentIndex + 1) % _activePlaylist.length;
    }
    notifyListeners();
  }

  Future<void> _submitStats(PlayItem item) async {
    try {
      final end = DateTime.now();
      final start = end.subtract(Duration(seconds: item.duration));
      String fmt(DateTime dt) =>
          '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-'
          '${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
      final statXml = '<stats>\n  <stat type="media" fromdt="${fmt(start)}" todt="${fmt(end)}" '
          'scheduleid="${item.scheduleId}" layoutid="${item.layoutId}" mediaid="${item.mediaId}" />\n</stats>';
      await XmdsService.instance.submitStats(statXml: statXml);
    } catch (_) {
      // Stats are non-critical.
    }
  }

  bool _samePlaylist(List<PlayItem> a, List<PlayItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].localPath != b[i].localPath || a[i].duration != b[i].duration) return false;
    }
    return true;
  }

  // ── Heartbeat ───────────────────────────────────────────────────────────────
  Future<void> _sendHeartbeat() async {
    try {
      final item = currentItem;
      final freeMB = await DownloadService.instance.getFreeSpaceMB();
      await XmdsService.instance.notifyStatus(
        layoutId: _currentLayoutId,
        freeMB: freeMB,
        lastMediaId: item?.mediaId ?? '0',
      );
    } catch (_) {
      // Heartbeat failure is non-critical.
    }
  }

  // ── XMR push ────────────────────────────────────────────────────────────────
  void _onCollectNow() {
    PlayerLogger.log('XMR', 'collectNow → running collection cycle');
    if (_state == PlayerState.playing ||
        _state == PlayerState.noContent ||
        _state == PlayerState.syncing ||
        _state == PlayerState.offline) {
      unawaited(runCollectionCycle());
    }
  }

  // ── Error backoff ───────────────────────────────────────────────────────────
  void _scheduleErrorRetry() {
    _errorTimer?.cancel();
    _errorRetryCountdown = _errorBackoffSeconds;
    notifyListeners();
    _errorTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      _errorRetryCountdown--;
      if (_errorRetryCountdown <= 0) {
        t.cancel();
        // Exponential backoff for the next failure.
        _errorBackoffSeconds =
            (_errorBackoffSeconds * 2).clamp(AppConstants.errorBackoffSeconds, AppConstants.maxErrorBackoffSeconds);
        retryNow();
      } else {
        notifyListeners();
      }
    });
  }

  /// [Retry Now] on the error screen, or auto-fired after backoff.
  Future<void> retryNow() async {
    _errorTimer?.cancel();
    _errorRetryCountdown = 0;
    _errorMessage = null;
    _errorCount = 0;
    final hasConfig = await StorageService.instance.hasConfig();
    if (!hasConfig) {
      transition(PlayerState.configuring, reason: 'retry → setup');
      return;
    }
    transition(PlayerState.registering, reason: 'retry');
    await _registerAndRoute();
  }

  /// [Reconfigure] on the error screen — clears config and returns to setup.
  Future<void> reconfigure() async {
    PlayerLogger.log('CONFIG', 'Reconfigure — clearing stored config');
    _stopTimers();
    await StorageService.instance.clearAll();
    _activePlaylist = [];
    _pendingPlaylist = null;
    _currentIndex = 0;
    _errorBackoffSeconds = AppConstants.errorBackoffSeconds;
    _errorMessage = null;
    transition(PlayerState.configuring, reason: 'reconfigure');
  }

  /// Fetch the diagnostics report for the no-content / error screens.
  Future<Map<String, dynamic>?> getDiagnostics() {
    return DiagnosticsService.instance.fetchDiagnostics(_hardwareKey);
  }

  // ── Teardown ────────────────────────────────────────────────────────────────
  void _stopTimers() {
    _collectionTimer?.cancel();
    _heartbeatTimer?.cancel();
    _statusPollTimer?.cancel();
    _errorTimer?.cancel();
    _collectionTimer = null;
    _heartbeatTimer = null;
    _statusPollTimer = null;
    _errorTimer = null;
  }

  @override
  void dispose() {
    _stopTimers();
    unawaited(XmrService.instance.dispose());
    super.dispose();
  }
}
