import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as IO;

import '../config/app_config.dart';
import '../utils/app_logger.dart';

class SocketService {
  SocketService._();
  static final SocketService instance = SocketService._();

  IO.Socket? _socket;
  String? _hardwareKey;
  String? _serverUrl;
  bool _isConnected = false;
  bool _connecting = false;
  bool _shuttingDown = false;
  DateTime? _lastReconnectCatchUp;
  int _socketGeneration = 0;
  Timer? _reIdentifyTimer;

  /// Interval for periodic re-identify to keep room membership alive.
  static const _reIdentifyIntervalSeconds = 120; // 2 minutes

  /// Increments whenever [init] creates a new socket — listeners must re-register.
  int get socketGeneration => _socketGeneration;

  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();

  bool get isConnected => _isConnected;

  Stream<bool> get connectionStream => _connectionController.stream;

  /// socket_io_client appends `:0` when no explicit port is given (Dart Uri.port quirk).
  /// Always pass :443 / :80 so the WebSocket handshake URL is valid.
  static String normalizeServerUrl(String serverUrl) {
    var url = serverUrl.trim();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }

    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;

    final host = uri.host;
    final scheme = uri.scheme.toLowerCase();

    if (scheme == 'https' || scheme == 'wss') {
      final port = uri.hasPort && uri.port > 0 ? uri.port : 443;
      return 'https://$host:$port';
    }
    if (scheme == 'http' || scheme == 'ws') {
      final port = uri.hasPort && uri.port > 0 ? uri.port : 80;
      return 'http://$host:$port';
    }

    return 'https://$host:443';
  }

  void init(String serverUrl, String hardwareKey) {
    if (_socket != null &&
        _serverUrl == normalizeServerUrl(serverUrl) &&
        _hardwareKey == hardwareKey &&
        !_shuttingDown) {
      AppLogger.socket('Already initialized — keeping single socket connection');
      if (!_isConnected && !_connecting) connect();
      return;
    }

    _hardwareKey = hardwareKey;
    _serverUrl = normalizeServerUrl(serverUrl);
    _shuttingDown = false;

    final normalizedUrl = _serverUrl!;
    AppLogger.socket('Initializing socket $normalizedUrl hardwareKey=$hardwareKey');

    _socket?.dispose();
    _socketGeneration++;
    _socket = IO.io(
      normalizedUrl,
      IO.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .setPath('/socket.io')
          .disableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(AppConfig.socketReconnectAttempts)
          .setReconnectionDelay(AppConfig.socketReconnectDelayMs)
          .setReconnectionDelayMax(AppConfig.socketReconnectDelayMaxMs)
          .setRandomizationFactor(0.5)
          .setQuery({'hardwareKey': hardwareKey})
          .setAuth({'hardwareKey': hardwareKey})
          .build(),
    );

    _socket!.onConnect((_) {
      _connecting = false;
      _isConnected = true;
      _connectionController.add(true);
      _identifyDevice();
      _startReIdentifyTimer();
      AppLogger.socketConnect('connect', {
        'socketId': _socket?.id ?? "(pending)",
        'hardwareKey': _hardwareKey,
      });
    });

    _socket!.onDisconnect((reason) {
      _connecting = false;
      _isConnected = false;
      _stopReIdentifyTimer();
      _connectionController.add(false);
      AppLogger.socketDisconnect('disconnect', {'reason': reason ?? "unknown"});
    });

    _socket!.onConnectError((err) {
      _connecting = false;
      _isConnected = false;
      AppLogger.socketDisconnect('connect_error', {'error': err?.toString() ?? "unknown"});
    });

    _socket!.onReconnect((_) {
      _connecting = false;
      _isConnected = true;
      _connectionController.add(true);
      // Bump generation so SocketEventHandler re-registers listeners
      _socketGeneration++;
      _identifyDevice();
      _startReIdentifyTimer();
      _onReconnectThrottled();
      AppLogger.socketConnect('reconnect', {
        'socketId': _socket?.id ?? "(pending)",
        'hardwareKey': _hardwareKey,
        'socketGeneration': _socketGeneration,
      });
    });

    _socket!.onAny((event, data) {
      AppLogger.socketEventReceived(event, data);
      if (AppConfig.isScreenshotSocketEvent(event)) {
        AppLogger.screenshotEventReceived('Socket.io', event, data);
      }
    });
  }

  void onAny(void Function(String event, dynamic data) handler) {
    _socket?.onAny(handler);
  }

  /// No-op — listeners are registered once in [PlayerInitService.initialize].
  void setOnReady(void Function() callback) {}

  void connect() {
    if (_shuttingDown || _socket == null) return;
    if (_isConnected || _connecting) {
      AppLogger.socket('Connect skipped — already connected or connecting');
      return;
    }
    _connecting = true;
    AppLogger.socket('Connecting...');
    _socket!.connect();
  }

  /// Safe manual reconnect (e.g. app resume) — only if actually disconnected.
  void reconnectIfNeeded() {
    if (_shuttingDown || _isConnected || _connecting) return;
    connect();
  }

  void disconnect() {
    if (_socket == null) return;
    _connecting = false;
    _stopReIdentifyTimer();
    _socket!.disconnect();
    _isConnected = false;
    _connectionController.add(false);
  }

  /// Force disconnect + reconnect — use on app resume to ensure fresh connection.
  /// Bumps socket generation so [SocketEventHandler] re-registers listeners.
  void forceReconnect() {
    if (_shuttingDown || _socket == null) return;
    AppLogger.socket('forceReconnect — tearing down and reconnecting');
    _stopReIdentifyTimer();
    _socket!.disconnect();
    _isConnected = false;
    _connecting = false;
    _connectionController.add(false);
    // Small delay so disconnect packet flushes before reconnect
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (_shuttingDown) return;
      connect();
    });
  }

  /// Check whether the socket is actually connected at the transport level.
  /// The [_isConnected] flag may be stale if Android killed the socket silently.
  bool get isActuallyConnected {
    if (_socket == null) return false;
    return _socket!.connected;
  }

  /// Validate connection and reconnect if the internal state is stale.
  void ensureConnected() {
    if (_shuttingDown || _socket == null) return;
    if (!isActuallyConnected) {
      AppLogger.socket('ensureConnected — socket claims connected but transport is dead, forcing reconnect');
      _isConnected = false;
      _connecting = false;
      forceReconnect();
    }
  }

  /// Permanent shutdown on app kill — disables reconnect and releases the socket.
  void shutdown() {
    AppLogger.socket('Shutdown — disconnecting permanently');
    _shuttingDown = true;
    _connecting = false;
    _stopReIdentifyTimer();
    _setManagerReconnection(false);
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _serverUrl = null;
    _isConnected = false;
    _connectionController.add(false);
  }

  void _setManagerReconnection(bool enabled) {
    try {
      final options = _socket?.io.options;
      if (options != null) {
        options['reconnection'] = enabled;
      }
    } catch (_) {}
  }

  void _identifyDevice() {
    if (_hardwareKey == null || _hardwareKey!.isEmpty) return;

    final payload = {
      'hardwareKey': _hardwareKey,
      'clientType': AppConfig.clientType,
      'clientVersion': AppConfig.clientVersion,
    };
    _socket?.emit('screen:identify', payload);
    AppLogger.socketEmit('screen:identify', payload);
  }

  /// Re-assert online status after returning from background.
  void reIdentify() {
    if (!_isConnected) return;
    _identifyDevice();
  }

  /// Tells the server to mark this screen offline immediately (home button / app kill).
  void emitGoingOffline() {
    if (_hardwareKey == null || _hardwareKey!.isEmpty) return;
    final payload = {'hardwareKey': _hardwareKey};
    _socket?.emit('screen:going_offline', payload);
    AppLogger.socketEmit('screen:going_offline', payload);
  }

  /// Emit offline event then wait so the packet can reach the server before disconnect.
  Future<void> emitGoingOfflineAndFlush() async {
    emitGoingOffline();
    await Future<void>.delayed(
      Duration(milliseconds: AppConfig.offlineNotifyFlushMs),
    );
  }

  // ── Periodic re-identify to keep room membership alive ──────────────────────

  void _startReIdentifyTimer() {
    _stopReIdentifyTimer();
    _reIdentifyTimer = Timer.periodic(
      const Duration(seconds: _reIdentifyIntervalSeconds),
      (_) {
        if (_isConnected && !_shuttingDown) {
          AppLogger.socket('Periodic re-identify (keep-alive)');
          _identifyDevice();
        }
      },
    );
  }

  void _stopReIdentifyTimer() {
    _reIdentifyTimer?.cancel();
    _reIdentifyTimer = null;
  }

  void _onReconnectThrottled() {
    final now = DateTime.now();
    final cooldown = Duration(
      seconds: AppConfig.socketReconnectCatchUpCooldownSeconds,
    );
    if (_lastReconnectCatchUp != null &&
        now.difference(_lastReconnectCatchUp!) < cooldown) {
      AppLogger.socket('Reconnect catch-up skipped (cooldown)');
      return;
    }
    _lastReconnectCatchUp = now;
    SocketEventBus.instance.emit(SocketEvent.reconnected, {});
  }

  void on(String event, Function(dynamic) handler) {
    _socket?.on(event, handler);
  }

  void off(String event, [Function(dynamic)? handler]) {
    if (handler != null) {
      _socket?.off(event, handler);
    } else {
      _socket?.off(event);
    }
  }

  void dispose() {
    shutdown();
  }
}

enum SocketEvent {
  screenApproved,
  syncNow,
  contentUpdated,
  scheduleActivated,
  schedulePaused,
  reconnected,
  screenshotRequested,
  deviceNotRegistered,
}

class SocketEventBus {
  SocketEventBus._();
  static final SocketEventBus instance = SocketEventBus._();

  final Map<SocketEvent, List<void Function(dynamic)>> _listeners = {};

  void on(SocketEvent event, void Function(dynamic) handler) {
    _listeners.putIfAbsent(event, () => []).add(handler);
  }

  void off(SocketEvent event, void Function(dynamic) handler) {
    _listeners[event]?.remove(handler);
  }

  void emit(SocketEvent event, dynamic data) {
    for (final handler in List<void Function(dynamic)>.from(
      _listeners[event] ?? [],
    )) {
      handler(data);
    }
  }
}
