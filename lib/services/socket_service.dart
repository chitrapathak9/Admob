import 'dart:async';
import 'dart:math' as math;

import 'package:socket_io_client/socket_io_client.dart' as IO;

import '../config/app_config.dart';
import '../utils/app_logger.dart';

class SocketService {
  SocketService._();
  static final SocketService instance = SocketService._();

  IO.Socket? _socket;
  String? _hardwareKey;
  bool _isConnected = false;
  bool _reconnectionPaused = false;
  int _connectFailures = 0;
  Timer? _backoffTimer;
  DateTime? _lastReconnectCatchUp;

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
    _hardwareKey = hardwareKey;
    _cancelBackoff();
    _connectFailures = 0;
    _reconnectionPaused = false;

    final normalizedUrl = normalizeServerUrl(serverUrl);
    AppLogger.socket('Connecting to $normalizedUrl');

    _socket?.dispose();
    _socket = IO.io(
      normalizedUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setPath('/socket.io')
          .disableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(AppConfig.socketReconnectAttempts)
          .setReconnectionDelay(AppConfig.socketReconnectDelayMs)
          .setReconnectionDelayMax(AppConfig.socketReconnectDelayMaxMs)
          .setRandomizationFactor(0.5)
          .build(),
    );

    _socket!.onConnect((_) {
      _connectFailures = 0;
      _reconnectionPaused = false;
      _cancelBackoff();
      _isConnected = true;
      _connectionController.add(true);
      _identifyDevice();
      AppLogger.socket('Connected');
    });

    _socket!.onDisconnect((_) {
      _isConnected = false;
      _connectionController.add(false);
      AppLogger.socket('Disconnected');
    });

    _socket!.onConnectError((err) {
      _handleConnectFailure(err);
    });

    _socket!.onReconnect((_) {
      _connectFailures = 0;
      _reconnectionPaused = false;
      _cancelBackoff();
      _isConnected = true;
      _connectionController.add(true);
      _identifyDevice();
      _onReconnectThrottled();
      AppLogger.socket('Reconnected');
    });
  }

  void connect() {
    if (_reconnectionPaused) {
      AppLogger.socket('Connect skipped — backoff active');
      return;
    }
    _socket?.connect();
  }

  /// Safe manual reconnect (e.g. app resume) — respects backoff pause.
  void reconnectIfNeeded() {
    if (_isConnected) return;
    if (_reconnectionPaused) {
      _scheduleBackoffReconnect();
      return;
    }
    connect();
  }

  void disconnect() {
    _cancelBackoff();
    _socket?.disconnect();
    _isConnected = false;
    _connectionController.add(false);
  }

  /// Permanent shutdown on app kill — disables reconnect and releases the socket.
  void shutdown() {
    AppLogger.socket('Shutdown — disconnecting permanently');
    _cancelBackoff();
    _reconnectionPaused = true;
    _setManagerReconnection(false);
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
    _isConnected = false;
    _connectionController.add(false);
  }

  void _handleConnectFailure(dynamic err) {
    _connectFailures++;
    final errStr = err?.toString() ?? '';
    AppLogger.socket('Connection error (#$_connectFailures): $errStr');

    final permanentFailure =
        errStr.contains('404') ||
        errStr.contains('403') ||
        errStr.contains('not upgraded');

    if (permanentFailure ||
        _connectFailures >= AppConfig.socketMaxFailuresBeforePause) {
      _pauseAutoReconnection();
      _scheduleBackoffReconnect();
    }
  }

  void _pauseAutoReconnection() {
    if (_reconnectionPaused) return;
    _reconnectionPaused = true;
    _setManagerReconnection(false);
    _socket?.disconnect();
    AppLogger.socket('Auto-reconnect paused (failures=$_connectFailures)');
  }

  void _scheduleBackoffReconnect() {
    _cancelBackoff();
    final exponent = math.min(_connectFailures, 8);
    final delayMs = math.min(
      AppConfig.socketBackoffMaxMs,
      AppConfig.socketBackoffBaseMs * math.pow(2, exponent).toInt(),
    );
    AppLogger.socket('Next reconnect attempt in ${delayMs ~/ 1000}s');

    _backoffTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_socket == null) return;
      _reconnectionPaused = false;
      _setManagerReconnection(true);
      AppLogger.socket('Backoff reconnect attempt');
      _socket?.connect();
    });
  }

  void _cancelBackoff() {
    _backoffTimer?.cancel();
    _backoffTimer = null;
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
    if (_hardwareKey != null && _hardwareKey!.isNotEmpty) {
      _socket?.emit('screen:identify', {'hardwareKey': _hardwareKey});
    }
  }

  /// Re-assert online status after returning from background.
  void reIdentify() => _identifyDevice();

  /// Tells the server to mark this screen offline immediately (home button / app kill).
  void emitGoingOffline() {
    if (_hardwareKey == null || _hardwareKey!.isEmpty) return;
    _socket?.emit('screen:going_offline', {'hardwareKey': _hardwareKey});
    AppLogger.socket('Emitted screen:going_offline hardwareKey=$_hardwareKey');
  }

  /// Emit offline event then wait so the packet can reach the server before disconnect.
  Future<void> emitGoingOfflineAndFlush() async {
    emitGoingOffline();
    await Future<void>.delayed(
      Duration(milliseconds: AppConfig.offlineNotifyFlushMs),
    );
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

  void off(String event) {
    _socket?.off(event);
  }

  void dispose() {
    _cancelBackoff();
    disconnect();
    _socket?.dispose();
    _socket = null;
  }
}

enum SocketEvent {
  screenApproved,
  syncNow,
  contentUpdated,
  scheduleActivated,
  schedulePaused,
  reconnected,
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
