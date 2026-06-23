import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_presentation_display/flutter_presentation_display.dart';
import 'package:path_provider/path_provider.dart';

import '../widgets/image_slide.dart';
import '../widgets/video_slide.dart';

/// Root app for the secondary (HDMI/presentation) display engine.
///
/// Launched by [secondaryDisplayMain] in main.dart when
/// [FlutterPresentationDisplay.showSecondaryDisplay] is called.
/// Runs in its own Flutter engine and Dart isolate — shares the on-disk
/// media cache with the primary engine but has no shared in-memory state.
///
/// Receives two messages from the primary engine via
/// [FlutterPresentationDisplay.listenDataFromMainDisplay]:
///   { action: 'setMedia',       mediaJson: `<json string>` }
///   { action: 'setOrientation', isPortrait: bool }
class SecondaryPlayerApp extends StatefulWidget {
  const SecondaryPlayerApp({super.key});

  @override
  State<SecondaryPlayerApp> createState() => _SecondaryPlayerAppState();
}

class _SecondaryPlayerAppState extends State<SecondaryPlayerApp> {
  final FlutterPresentationDisplay _display = FlutterPresentationDisplay();

  List<_MediaEntry> _playlist = [];
  int _currentIndex = 0;
  int _slideKey = 0;

  /// True when the mastered content is portrait (9:16).
  /// False (default) means landscape (16:9).
  bool _isPortraitContent = false;

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
        // unawaited — errors are caught inside _handleSetMedia
        _handleSetMedia(msg['mediaJson'] as String? ?? '').catchError((Object e) {
          debugPrint('[Secondary] setMedia unhandled error: $e');
        });
      case 'setOrientation':
        if (!mounted) return;
        setState(() {
          _isPortraitContent = (msg['isPortrait'] as bool?) ?? false;
        });
    }
  }

  Future<void> _handleSetMedia(String mediaJson) async {
    if (mediaJson.isEmpty) return;
    try {
      final rawList = jsonDecode(mediaJson) as List<dynamic>;
      final appDir = await getApplicationDocumentsDirectory();
      final mediaDir = '${appDir.path}/media';

      final entries = <_MediaEntry>[];
      for (final raw in rawList) {
        final m = Map<String, dynamic>.from(raw as Map);
        final filename = m['filename'] as String? ?? '';
        if (filename.isEmpty) continue;

        final path = '$mediaDir/$filename';
        if (!await File(path).exists()) {
          debugPrint('[Secondary] file not on disk, skipping: $filename');
          continue;
        }

        entries.add(_MediaEntry(
          localPath: path,
          type: m['type'] as String? ?? 'image',
          duration: (m['duration'] as num?)?.toInt() ?? 10,
        ));
      }

      // If no files resolved (e.g. HDMI reconnect before download completes),
      // keep the current playlist playing rather than going black.
      if (entries.isEmpty) {
        debugPrint('[Secondary] setMedia: no files ready on disk — keeping current playlist');
        return;
      }

      if (!mounted) return;
      setState(() {
        _playlist = entries;
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: _playlist.isEmpty
            ? const SizedBox.expand(child: ColoredBox(color: Colors.black))
            : _OrientationWrapper(
                isPortraitContent: _isPortraitContent,
                child: KeyedSubtree(
                  key: ValueKey<int>(_slideKey),
                  child: _buildSlide(
                    _playlist[_currentIndex % _playlist.length],
                  ),
                ),
              ),
      ),
    );
  }

  static const _videoExtensions = {'.mp4', '.mov', '.mkv', '.webm', '.m4v'};

  Widget _buildSlide(_MediaEntry entry) {
    final isVideo = entry.type == 'video' ||
        _videoExtensions.any(entry.localPath.toLowerCase().endsWith);

    return isVideo
        ? VideoSlide(
            localPath: entry.localPath,
            duration: entry.duration,
            onComplete: _onItemComplete,
          )
        : ImageSlide(
            localPath: entry.localPath,
            duration: entry.duration,
            onComplete: _onItemComplete,
          );
  }
}

// ── Internal data class ───────────────────────────────────────────────────────

class _MediaEntry {
  const _MediaEntry({
    required this.localPath,
    required this.type,
    required this.duration,
  });

  final String localPath;
  final String type;
  final int duration;
}

// ── Orientation mismatch handler ──────────────────────────────────────────────

/// Rotates [child] 90° when the mastered content orientation does not match
/// the physical screen orientation, then sizes it to fill the screen.
///
/// Examples:
///   Portrait content on landscape screen  → quarterTurns: 1
///   Landscape content on portrait screen  → quarterTurns: 3
class _OrientationWrapper extends StatelessWidget {
  const _OrientationWrapper({
    required this.isPortraitContent,
    required this.child,
  });

  final bool isPortraitContent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final screenIsPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;

    // Content and screen orientations match — render as-is.
    if (isPortraitContent == screenIsPortrait) return child;

    // Rotate 90° and swap width/height so the content fills the screen.
    return RotatedBox(
      quarterTurns: isPortraitContent ? 1 : 3,
      child: SizedBox(
        width: MediaQuery.of(context).size.height,
        height: MediaQuery.of(context).size.width,
        child: child,
      ),
    );
  }
}
