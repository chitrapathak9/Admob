import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_presentation_display/flutter_presentation_display.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../widgets/image_slide.dart';
import '../widgets/video_slide.dart';

/// Root app for the secondary (HDMI/presentation) display engine.
///
/// Launched by [secondaryDisplayMain] in main.dart when
/// [FlutterPresentationDisplay.showSecondaryDisplay] is called.
/// Runs in its own Flutter engine and Dart isolate — shares the on-disk
/// media cache with the primary engine but has no shared in-memory state.
///
/// # Orientation handling
///
/// Primary and secondary screens can have completely different physical
/// orientations (e.g. primary = portrait, secondary = landscape).
/// Each media item carries its own `isPortraitContent` flag (derived from
/// the `orientation` field in the manifest JSON).  The [_OrientationWrapper]
/// is applied **per slide**, not around the entire player, so a playlist that
/// mixes portrait and landscape content is handled correctly with zero race
/// conditions.
///
/// Resolution of each item:
///   1. Local file at `<appDocDir>/media/<filename>` (normal cached flow).
///   2. `downloadUrl` streamed over the network (mock / test items, or
///      content not yet downloaded on the secondary engine).
///
/// Supported messages from the primary engine:
///   { action: 'setMedia', mediaJson: '<json string>' }
///
/// The `setOrientation` message is **no longer used** — orientation is now
/// embedded per item in the mediaJson so there are no race conditions.
class SecondaryPlayerApp extends StatefulWidget {
  const SecondaryPlayerApp({super.key});

  @override
  State<SecondaryPlayerApp> createState() => _SecondaryPlayerAppState();
}

class _SecondaryPlayerAppState extends State<SecondaryPlayerApp> {
  final FlutterPresentationDisplay _display = FlutterPresentationDisplay();
  final GlobalKey _repaintKey = GlobalKey();

  List<_MediaEntry> _playlist = [];
  int _currentIndex = 0;
  int _slideKey = 0;
  // Mirrors the primary engine's blank state — pushed via 'setBlanked'.
  // Same render-overlay approach: playback keeps running underneath.
  bool _isBlanked = false;

  @override
  void initState() {
    super.initState();
    _display.listenDataFromMainDisplay(_onDataReceived);
  }

  void _onDataReceived(dynamic data) {
    if (data is! Map) return;
    final msg = Map<String, dynamic>.from(data);

    switch (msg['action'] as String?) {
      case 'setMedia':
        _handleSetMedia(msg['mediaJson'] as String? ?? '').catchError((Object e) {
          debugPrint('[Secondary] setMedia unhandled error: $e');
        });

      // setOrientation is kept for backward compatibility but orientation is
      // now embedded per-item in setMedia — this branch is a no-op.
      case 'setOrientation':
        debugPrint('[Secondary] setOrientation received (ignored — orientation is per-item)');

      case 'setBlanked':
        final blanked = msg['isBlanked'] as bool? ?? false;
        if (blanked != _isBlanked && mounted) {
          setState(() => _isBlanked = blanked);
        }

      case 'takeScreenshot':
        final requestId = msg['requestId'] as String?;
        _captureAndSendScreenshot(requestId).catchError((Object e) {
          debugPrint('[Secondary] takeScreenshot unhandled error: $e');
        });
    }
  }

  Future<void> _captureAndSendScreenshot(String? requestId) async {
    // Wait for the next frame so the current slide is fully painted.
    await Future<void>.delayed(Duration.zero);

    final boundary = _repaintKey.currentContext?.findRenderObject()
        as RenderRepaintBoundary?;

    if (boundary == null) {
      await _display.transferDataToMain({
        'action'   : 'screenshotError',
        'requestId': requestId,
        'error'    : 'RepaintBoundary not found',
      });
      return;
    }

    try {
      final pixelRatio =
          WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
      final image    = await boundary.toImage(pixelRatio: pixelRatio);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw Exception('toByteData returned null');

      final pngBytes = byteData.buffer.asUint8List();
      final appDir   = await getApplicationDocumentsDirectory();
      final safeId   = requestId?.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_') ?? 'noId';
      final filePath = '${appDir.path}/screenshots/secondary_ss_$safeId.png';

      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(pngBytes);

      debugPrint('[Secondary] screenshot saved: $filePath (${pngBytes.length} bytes)');
      await _display.transferDataToMain({
        'action'   : 'screenshotResult',
        'requestId': requestId,
        'filePath' : filePath,
      });
    } catch (e) {
      debugPrint('[Secondary] screenshot capture error: $e');
      await _display.transferDataToMain({
        'action'   : 'screenshotError',
        'requestId': requestId,
        'error'    : e.toString(),
      });
    }
  }

  Future<void> _handleSetMedia(String mediaJson) async {
    if (mediaJson.isEmpty) return;
    try {
      final rawList  = jsonDecode(mediaJson) as List<dynamic>;
      final appDir   = await getApplicationDocumentsDirectory();
      final mediaDir = '${appDir.path}/media';

      final entries = <_MediaEntry>[];
      for (final raw in rawList) {
        final m           = Map<String, dynamic>.from(raw as Map);
        final filename    = m['filename']    as String? ?? '';
        final downloadUrl = m['downloadUrl'] as String? ?? '';
        final type        = m['type']        as String? ?? 'image';
        final duration    = (m['duration']   as num?)?.toInt() ?? 10;

        // ── Orientation: embedded per-item ───────────────────────────────
        // 'portrait' | 'landscape' — defaults to landscape when absent.
        // The secondary screen reads its OWN physical orientation from
        // MediaQuery at render time and rotates content if needed.
        final isPortraitContent =
            (m['orientation'] as String? ?? 'landscape') == 'portrait';

        // ── Priority 1: local file on disk ───────────────────────────────
        if (filename.isNotEmpty) {
          final path = '$mediaDir/$filename';
          if (await File(path).exists()) {
            entries.add(_MediaEntry(
              source           : path,
              type             : type,
              duration         : duration,
              isNetwork        : false,
              isPortraitContent: isPortraitContent,
            ));
            continue;
          }
          debugPrint('[Secondary] file not on disk: $filename');
        }

        // ── Priority 2: stream directly from downloadUrl ─────────────────
        // Used for mock/test items (e.g. Cloudinary) or content not yet
        // cached by the primary download service.
        if (downloadUrl.isNotEmpty) {
          debugPrint('[Secondary] network fallback: $downloadUrl');
          entries.add(_MediaEntry(
            source           : downloadUrl,
            type             : type,
            duration         : duration,
            isNetwork        : true,
            isPortraitContent: isPortraitContent,
          ));
          continue;
        }

        debugPrint('[Secondary] skipping — no local file or download URL');
      }

      // Keep current playlist playing rather than going black if nothing resolved
      // (e.g. HDMI reconnect before download completes).
      if (entries.isEmpty) {
        debugPrint('[Secondary] setMedia: nothing ready — keeping current playlist');
        return;
      }

      if (!mounted) return;
      setState(() {
        _playlist     = entries;
        _currentIndex = 0;
        _slideKey++;
      });

      debugPrint('[Secondary] playlist updated: ${entries.length} item(s)');
    } catch (e) {
      debugPrint('[Secondary] setMedia parse error: $e');
    }
  }

  void _onItemComplete() {
    if (!mounted || _playlist.isEmpty) return;
    setState(() {
      _currentIndex = (_currentIndex + 1) % _playlist.length;
      _slideKey++;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_playlist.isEmpty) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SizedBox.expand(child: ColoredBox(color: Colors.black)),
        ),
      );
    }

    final entry = _playlist[_currentIndex % _playlist.length];

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        // _OrientationWrapper is applied PER SLIDE so each item uses its
        // own content orientation vs the secondary screen's physical
        // orientation, read fresh from MediaQuery on every rebuild.
        body: Stack(
          children: [
            RepaintBoundary(
              key: _repaintKey,
              child: _OrientationWrapper(
                isPortraitContent: entry.isPortraitContent,
                child: KeyedSubtree(
                  key: ValueKey<int>(_slideKey),
                  child: _buildSlide(entry),
                ),
              ),
            ),
            if (_isBlanked)
              const Positioned.fill(child: ColoredBox(color: Colors.black)),
          ],
        ),
      ),
    );
  }

  static const _videoExtensions = {'.mp4', '.mov', '.mkv', '.webm', '.m4v'};

  Widget _buildSlide(_MediaEntry entry) {
    final isVideo = entry.type == 'video' ||
        _videoExtensions.any(entry.source.toLowerCase().endsWith);

    if (entry.isNetwork) {
      return isVideo
          ? _NetworkVideoSlide(
              url       : entry.source,
              duration  : entry.duration,
              onComplete: _onItemComplete,
            )
          : _NetworkImageSlide(
              url       : entry.source,
              duration  : entry.duration,
              onComplete: _onItemComplete,
            );
    }

    return isVideo
        ? VideoSlide(
            localPath : entry.source,
            duration  : entry.duration,
            onComplete: _onItemComplete,
          )
        : ImageSlide(
            localPath : entry.source,
            duration  : entry.duration,
            onComplete: _onItemComplete,
          );
  }
}

// ── Internal data class ───────────────────────────────────────────────────────

class _MediaEntry {
  const _MediaEntry({
    required this.source,
    required this.type,
    required this.duration,
    required this.isNetwork,
    required this.isPortraitContent,
  });

  /// Absolute file path (isNetwork=false) or HTTPS URL (isNetwork=true).
  final String source;
  final String type;
  final int    duration;

  /// True when this item must be fetched over the network instead of from disk.
  final bool isNetwork;

  /// True when the content was mastered in portrait (9:16) aspect ratio.
  /// Derived from the `orientation` field in the manifest JSON.
  /// The [_OrientationWrapper] uses this to rotate when the secondary
  /// screen's physical orientation differs.
  final bool isPortraitContent;
}

// ── Network image slide ───────────────────────────────────────────────────────

class _NetworkImageSlide extends StatefulWidget {
  const _NetworkImageSlide({
    required this.url,
    required this.duration,
    required this.onComplete,
  });

  final String       url;
  final int          duration;
  final VoidCallback onComplete;

  @override
  State<_NetworkImageSlide> createState() => _NetworkImageSlideState();
}

class _NetworkImageSlideState extends State<_NetworkImageSlide> {
  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(seconds: widget.duration), () {
      if (mounted) widget.onComplete();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Image.network(
        widget.url,
        fit   : BoxFit.contain,
        width : double.infinity,
        height: double.infinity,
        loadingBuilder: (_, child, progress) => progress == null
            ? child
            : const Center(child: CircularProgressIndicator(color: Colors.white)),
        errorBuilder: (_, __, ___) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => widget.onComplete(),
          );
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

// ── Network video slide ───────────────────────────────────────────────────────

class _NetworkVideoSlide extends StatefulWidget {
  const _NetworkVideoSlide({
    required this.url,
    required this.duration,
    required this.onComplete,
  });

  final String       url;
  final int          duration;
  final VoidCallback onComplete;

  @override
  State<_NetworkVideoSlide> createState() => _NetworkVideoSlideState();
}

class _NetworkVideoSlideState extends State<_NetworkVideoSlide> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (!mounted) return;
        setState(() => _initialized = true);
        _controller
          ..play()
          ..addListener(_onVideoProgress);
      }).catchError((Object e) {
        debugPrint('[Secondary] network video init failed: $e');
        if (mounted) widget.onComplete();
      });
  }

  void _onVideoProgress() {
    if (!_controller.value.isInitialized) return;
    if (!_controller.value.isPlaying &&
        _controller.value.position >= _controller.value.duration) {
      widget.onComplete();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onVideoProgress);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: _controller.value.aspectRatio,
          child: VideoPlayer(_controller),
        ),
      ),
    );
  }
}

// ── Per-slide orientation adapter ─────────────────────────────────────────────

/// Rotates [child] 90° when the media's mastered content orientation does not
/// match the **secondary screen's** physical orientation (read independently
/// from [MediaQuery] of this Flutter engine — completely separate from the
/// primary screen's orientation lock).
///
/// Applied per-slide so mixed-orientation playlists are handled correctly.
///
/// Examples:
///   Content portrait  + screen landscape → RotatedBox(quarterTurns: 1)
///   Content landscape + screen portrait  → RotatedBox(quarterTurns: 3)
///   Orientations match                   → no rotation, rendered as-is
class _OrientationWrapper extends StatelessWidget {
  const _OrientationWrapper({
    required this.isPortraitContent,
    required this.child,
  });

  final bool   isPortraitContent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Read from the SECONDARY screen's MediaQuery — this is a separate Flutter
    // engine and does NOT share SystemChrome orientation locks with the primary.
    final screenIsPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;

    // Orientations match — render content as-is with BoxFit.contain in slides.
    if (isPortraitContent == screenIsPortrait) return child;

    // Mismatch: rotate 90° and swap the logical width/height so the content
    // fills the screen without black bars on the wrong axis.
    return RotatedBox(
      quarterTurns: isPortraitContent ? 1 : 3,
      child: SizedBox(
        width : MediaQuery.of(context).size.height,
        height: MediaQuery.of(context).size.width,
        child : child,
      ),
    );
  }
}
