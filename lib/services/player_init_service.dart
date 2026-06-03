import 'dart:async';

import 'package:flutter/widgets.dart';

import '../config/app_config.dart';
import '../utils/app_logger.dart';
import 'config_service.dart';
import 'heartbeat_service.dart';
import 'player_service.dart';
import 'screen_service.dart';
import 'socket_event_handler.dart';
import 'socket_service.dart';
import 'storage_service.dart';
import 'xmds_service.dart';
import 'xmr_service.dart';

class PlayerInitService with WidgetsBindingObserver {
  PlayerInitService._();
  static final PlayerInitService instance = PlayerInitService._();

  final SocketService _socketService = SocketService.instance;
  final SocketEventHandler _eventHandler = SocketEventHandler();
  bool _initialized = false;
  bool _reconnectListenerRegistered = false;
  bool _shuttingDown = false;

  Future<void> initialize() async {
    if (_initialized) return;

    WidgetsBinding.instance.addObserver(this);

    String serverUrl = AppConfig.baseUrl;
    try {
      final config = await ConfigService.instance.fetchConfig();
      if (config.playerDomain != null && config.playerDomain!.isNotEmpty) {
        serverUrl = config.playerDomain!;
      }
    } catch (e, st) {
      AppLogger.config(
        'fetchConfig failed on init — using cached/base URL: $e',
      );
      AppLogger.apiError('Config', 'init fallback', e, st);
      final cached = await StorageService.instance.loadConfig();
      if (cached?.playerDomain != null && cached!.playerDomain!.isNotEmpty) {
        serverUrl = cached.playerDomain!;
      }
    }

    final hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
    _socketService.init(serverUrl, hardwareKey);
    _socketService.connect();
    _eventHandler.registerAll();
    _registerReconnectListener();
    _initialized = true;

    AppLogger.socket(
      'Initialized serverUrl=$serverUrl hardwareKey=$hardwareKey',
    );

    unawaited(_checkInitialScreenStatus(hardwareKey));
  }

  void _registerReconnectListener() {
    if (_reconnectListenerRegistered) return;
    _reconnectListenerRegistered = true;

    SocketEventBus.instance.on(SocketEvent.reconnected, (_) async {
      AppLogger.socket('Reconnect catch-up');
      await _eventHandler.catchUpAfterReconnect();
    });
  }

  Future<void> _checkInitialScreenStatus(String hardwareKey) async {
    try {
      final status = await ScreenService.instance.getStatus(hardwareKey);
      await StorageService.instance.saveRegistrationStatus(status.status);

      if (!status.isApprovedOrActive) return;

      await StorageService.instance.setApproved(true);
      final displayName = await StorageService.instance.loadDisplayName();
      if (displayName == null || displayName.isEmpty) return;

      await XmdsService.instance.registerDisplay(displayName);
      await _eventHandler.catchUpAfterReconnect();
    } catch (e, st) {
      AppLogger.apiError('Socket', 'Initial status check failed', e, st);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_shuttingDown) return;

    switch (state) {
      case AppLifecycleState.resumed:
        HeartbeatService.instance.resumeFromBackground();
        AppLogger.heartbeat('App foreground — heartbeat active, socket reconnect if needed');
        if (_socketService.isConnected) {
          _socketService.reIdentify();
        } else {
          _socketService.reconnectIfNeeded();
        }
      case AppLifecycleState.paused:
        unawaited(_handleBackground());
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        AppLogger.heartbeat('App backgrounded — socket stays connected');
      case AppLifecycleState.detached:
        unawaited(_shutdownConnections());
    }
  }

  Future<void> _handleBackground() async {
    HeartbeatService.instance.pauseForBackground();
    AppLogger.offline('[BG] App paused — calling offline API before background notify');

    final offlineOk = await PlayerService.instance.markScreenOffline();
    if (!offlineOk) {
      AppLogger.offline('[BG] Offline API failed — skipping screen:going_offline emit');
      return;
    }

    AppLogger.offline('[BG] Offline API OK — emitting screen:going_offline');
    await _socketService.emitGoingOfflineAndFlush();
    AppLogger.offline('[BG] Background offline flow complete');
  }

  Future<void> _notifyServerOffline({required bool disconnectAfter}) async {
    AppLogger.socket('Notifying server offline (disconnectAfter=$disconnectAfter)');
    await _socketService.emitGoingOfflineAndFlush();

    if (disconnectAfter) {
      _eventHandler.unregisterAll();
      _socketService.shutdown();
      unawaited(XmrService.instance.dispose());
      AppLogger.offline('[KILL] Socket disconnected — shutdown complete');
    }
  }

  Future<void> _shutdownConnections() async {
    if (_shuttingDown) {
      AppLogger.offline('[KILL] Shutdown already in progress — skip');
      return;
    }
    _shuttingDown = true;

    AppLogger.offline('[KILL] ═══ App kill detected ═══');
    AppLogger.offline('[KILL] Step 1/3 — stop heartbeat timer');
    HeartbeatService.instance.stop();

    AppLogger.offline(
      '[KILL] Step 2/3 — POST /api/v1/player/offline (required — will NOT disconnect if this fails)',
    );
    final offlineOk = await PlayerService.instance.markScreenOffline();

    if (!offlineOk) {
      AppLogger.offline(
        '[KILL] ABORT — offline API failed or not confirmed; socket stays connected, app NOT killed',
      );
      _shuttingDown = false;
      return;
    }

    AppLogger.offline('[KILL] Step 3/3 — offline API success; disconnecting socket now');
    await _notifyServerOffline(disconnectAfter: true);

    WidgetsBinding.instance.removeObserver(this);
    _initialized = false;
    AppLogger.offline('[KILL] ═══ Shutdown finished ═══');
  }
}
