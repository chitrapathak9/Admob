import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_presentation_display/display.dart';
import 'package:flutter_presentation_display/flutter_presentation_display.dart';

import '../models/player_manifest.dart';
import 'socket_service.dart';

/// Manages the secondary (HDMI/presentation) physical display.
///
/// Responsibilities:
///   - Discover connected displays on startup via [initialize].
///   - Subscribe to OS display-change events and re-emit them as
///     [SocketEvent.displayChanged] so [PlayerScreen] can react.
///   - Launch the secondary Flutter engine via [launchSecondaryScreen].
///   - Push updated media playlists to the secondary engine via
///     [pushMediaToSecondary] (call this on every schedule refresh instead of
///     re-launching to avoid the engine-restart black flash).
///   - Report connected display count via [getDisplayCountPayload] for the
///     `display_count_response` socket event.
class DisplayManagerService {
  DisplayManagerService._();
  static final DisplayManagerService instance = DisplayManagerService._();

  final FlutterPresentationDisplay _display = FlutterPresentationDisplay();

  List<Display> _connectedDisplays = [];
  bool _secondaryActive = false;
  StreamSubscription<int?>? _displayChangeSubscription;

  // Pending completers waiting for a screenshot result from the secondary engine.
  final Map<String?, Completer<String>> _screenshotCompleters = {};

  /// Immutable snapshot of currently connected physical displays.
  List<Display> get connectedDisplays => List.unmodifiable(_connectedDisplays);

  /// Total number of physical displays visible to the OS.
  int get displayCount => _connectedDisplays.length;

  /// True when more than one physical display is connected.
  bool get hasSecondaryDisplay => _connectedDisplays.length > 1;

  /// True after [launchSecondaryScreen] succeeds and until [dismissSecondary]
  /// or physical disconnect.
  bool get secondaryActive => _secondaryActive;

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  /// Refresh the display list and (re)subscribe to OS connect/disconnect events.
  ///
  /// Safe to call multiple times — cancels any prior subscription first.
  Future<void> initialize() async {
    await _refreshDisplayList();
    _subscribeToDisplayChanges();
    // Listen for screenshot results (and errors) sent back from the secondary engine.
    _display.listenDataFromPresentationDisplay(_onDataFromSecondary);
  }

  void _onDataFromSecondary(dynamic data) {
    if (data is! Map) return;
    final msg       = Map<String, dynamic>.from(data);
    final action    = msg['action']    as String?;
    final requestId = msg['requestId'] as String?;

    if (action == 'screenshotResult') {
      final filePath = msg['filePath'] as String?;
      final completer = _screenshotCompleters.remove(requestId);
      if (filePath != null && completer != null && !completer.isCompleted) {
        completer.complete(filePath);
      }
    } else if (action == 'screenshotError') {
      final error     = msg['error'] as String? ?? 'unknown error';
      final completer = _screenshotCompleters.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(Exception('Secondary screenshot failed: $error'));
      }
    }
  }

  /// Request a screenshot from the secondary display engine.
  ///
  /// Returns the local file path of the captured PNG, or null on timeout/error.
  Future<String?> requestSecondaryScreenshot(String? requestId) async {
    if (!_secondaryActive) return null;

    final completer = Completer<String>();
    _screenshotCompleters[requestId] = completer;

    try {
      await _display.transferDataToPresentation({
        'action'   : 'takeScreenshot',
        'requestId': requestId,
      });
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _screenshotCompleters.remove(requestId);
      debugPrint('[DisplayManager] Secondary screenshot timed out (requestId=$requestId)');
      return null;
    } catch (e) {
      _screenshotCompleters.remove(requestId);
      debugPrint('[DisplayManager] Secondary screenshot error: $e');
      return null;
    }
  }

  Future<void> _refreshDisplayList() async {
    try {
      final displays = await _display.getDisplays();
      _connectedDisplays = displays ?? [];
      debugPrint('[DisplayManager] ${_connectedDisplays.length} display(s) found');
    } catch (e) {
      debugPrint('[DisplayManager] getDisplays failed: $e');
      _connectedDisplays = [];
    }
  }

  void _subscribeToDisplayChanges() {
    _displayChangeSubscription?.cancel();
    _displayChangeSubscription =
        _display.connectedDisplaysChangedStream.listen((int? displayId) async {
      debugPrint('[DisplayManager] display change event — id=$displayId');
      await _refreshDisplayList();
      // Notify PlayerScreen (Section 5 registers the listener).
      SocketEventBus.instance.emit(SocketEvent.displayChanged, _connectedDisplays);
      // If the secondary screen physically disconnected, reset the active flag
      // so the next reconnect triggers a fresh launch.
      if (_secondaryActive && !hasSecondaryDisplay) {
        _secondaryActive = false;
        debugPrint('[DisplayManager] Secondary physically disconnected — marking inactive');
      }
    });
  }

  // ── Secondary display control ───────────────────────────────────────────────

  /// Launch the secondary Flutter engine on the non-primary physical display.
  ///
  /// After a successful launch, push content immediately via
  /// [pushMediaToSecondary]. On subsequent schedule refreshes call
  /// [pushMediaToSecondary] directly — do NOT re-call this method, as it
  /// restarts the engine and causes a brief black flash on screen 2.
  ///
  /// Returns `true` if the engine was launched (or was already active).
  Future<bool> launchSecondaryScreen() async {
    if (!hasSecondaryDisplay) {
      debugPrint('[DisplayManager] No secondary display connected — skipping launch');
      return false;
    }
    if (_secondaryActive) {
      debugPrint('[DisplayManager] Secondary already active — skipping re-launch');
      return true;
    }
    try {
      final primary   = _connectedDisplays.first;
      final secondary = _connectedDisplays.firstWhere(
        (d) => d.displayId != primary.displayId,
        orElse: () => _connectedDisplays.last,
      );
      final result = await _display.showSecondaryDisplay(
        displayId : secondary.displayId ?? 1,
        routerName: 'secondaryDisplayMain', // must match @pragma name in main.dart
      );
      if (result == true) {
        _secondaryActive = true;
        debugPrint('[DisplayManager] Secondary display launched — id=${secondary.displayId}');
      } else {
        debugPrint('[DisplayManager] showSecondaryDisplay returned false — id=${secondary.displayId}');
      }
      return result ?? false;
    } catch (e) {
      debugPrint('[DisplayManager] launchSecondaryScreen error: $e');
      return false;
    }
  }

  /// Serialize [media] and push the playlist to the secondary engine.
  ///
  /// No-ops silently when [secondaryActive] is false — safe to call
  /// unconditionally on schedule refresh.
  Future<void> pushMediaToSecondary(List<ManifestMediaItem> media) async {
    if (!_secondaryActive) return;
    try {
      final payload = media
          .map((m) => {
                'order'      : m.order,
                'name'       : m.name,
                'filename'   : m.filename,
                'downloadUrl': m.downloadUrl,
                'type'       : m.type,
                'duration'   : m.duration,
                'fileSize'   : m.fileSize,
                'orientation': m.orientation,
              })
          .toList();
      await _display.transferDataToPresentation({
        'action'   : 'setMedia',
        'mediaJson': jsonEncode(payload),
      });
      debugPrint('[DisplayManager] pushed ${media.length} item(s) to secondary');
      for (final m in media) {
        debugPrint('[DisplayManager]   ‣ ${m.name} | ${m.type} | ${m.orientation} | file=${m.filename}');
      }
    } catch (e) {
      debugPrint('[DisplayManager] pushMediaToSecondary error: $e');
    }
  }

  /// Tell the secondary engine whether its content is portrait-mastered so it
  /// can apply a [RotatedBox] when screen and content orientation diverge.
  Future<void> pushOrientationToSecondary({required bool isPortrait}) async {
    if (!_secondaryActive) return;
    try {
      await _display.transferDataToPresentation({
        'action'    : 'setOrientation',
        'isPortrait': isPortrait,
      });
    } catch (e) {
      debugPrint('[DisplayManager] pushOrientationToSecondary error: $e');
    }
  }

  /// Hide the secondary display and mark the engine as inactive.
  Future<void> dismissSecondary() async {
    if (!_secondaryActive) return;
    try {
      if (_connectedDisplays.length > 1) {
        await _display.hideSecondaryDisplay(
          displayId: _connectedDisplays.last.displayId ?? 1,
        );
      }
    } catch (e) {
      debugPrint('[DisplayManager] dismissSecondary error: $e');
    } finally {
      _secondaryActive = false;
      debugPrint('[DisplayManager] Secondary display dismissed');
    }
  }

  // ── Socket payload ──────────────────────────────────────────────────────────

  /// Build the payload for a `display_count_response` socket event.
  ///
  /// [deviceDisplayId] is the Xibo displayId from the manifest — it lets the
  /// admin panel correlate this response to the device that was queried.
  Map<String, dynamic> getDisplayCountPayload(int deviceDisplayId) {
    return {
      'displayId'        : deviceDisplayId,
      'connectedDisplays': _connectedDisplays.length,
      'displayDetails'   : _connectedDisplays.asMap().entries.map((e) => {
        'id'      : e.value.displayId ?? e.key,
        'name'    : e.value.name ?? 'Display ${e.key + 1}',
        'isPrimary': e.key == 0,
      }).toList(),
    };
  }
}
