import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoSlide extends StatefulWidget {
	final String localPath;
	final int duration;
	final VoidCallback onComplete;

	const VideoSlide({
		super.key,
		required this.localPath,
		required this.duration,
		required this.onComplete,
	});

	@override
	State<VideoSlide> createState() => _VideoSlideState();
}

class _VideoSlideState extends State<VideoSlide> {
	VideoPlayerController? _controller;
	bool _completed = false;
	Timer? _durationTimer;

	@override
	void initState() {
		super.initState();
		// Playlist advancement is driven by this timer, not the video's natural length.
		// A 10 s clip in a 30 s slot loops 3× and then advances.
		final playSeconds = widget.duration > 0 ? widget.duration : 30;
		_durationTimer = Timer(Duration(seconds: playSeconds), _finish);
		_init();
	}

	Future<void> _init() async {
		final file = File(widget.localPath);

		if (!file.existsSync()) {
			debugPrint('[VideoSlide] File not found: ${widget.localPath}');
			// Do NOT call _finish here — let the duration timer fire naturally
			// so the slot length is respected even when the file is missing.
			return;
		}

		VideoPlayerController? ctrl;
		try {
			ctrl = VideoPlayerController.file(file);
			await ctrl.initialize();

			if (!mounted) {
				await ctrl.dispose();
				return;
			}

			if (!ctrl.value.isInitialized) {
				debugPrint('[VideoSlide] initialize() returned but isInitialized=false: ${widget.localPath}');
				await ctrl.dispose();
				return;
			}

			await ctrl.setLooping(true);
			ctrl.addListener(_onControllerUpdate);

			// ── CRITICAL ORDER ──────────────────────────────────────────────────
			// 1. Put the VideoPlayer widget into the tree FIRST.
			//    This lets the Flutter engine create the SurfaceTexture /
			//    AndroidExternalTexture that ExoPlayer will render frames onto.
			setState(() => _controller = ctrl);

			// 2. Start playback AFTER the next frame is painted.
			//    Calling play() before the texture is attached causes ExoPlayer to
			//    decode internally but have nothing to render to — the video appears
			//    frozen on the first frame (the classic "thumbnail" symptom).
			WidgetsBinding.instance.addPostFrameCallback((_) {
				if (mounted && !_completed) {
					_controller?.play();
				}
			});
		} catch (e, st) {
			debugPrint('[VideoSlide] Init failed path=${widget.localPath}: $e');
			debugPrint('[VideoSlide] Stack: $st');
			await ctrl?.dispose();
			// Duration timer drives playlist advancement; no need to call _finish here.
		}
	}

	void _onControllerUpdate() {
		if (_completed || _controller == null) return;
		if (_controller!.value.hasError) {
			debugPrint('[VideoSlide] Playback error: ${_controller!.value.errorDescription}');
			// Let the timer expire naturally instead of skipping immediately.
		}
	}

	void _finish() {
		if (_completed) return;
		_completed = true;
		widget.onComplete();
	}

	@override
	void dispose() {
		_durationTimer?.cancel();
		_controller?.removeListener(_onControllerUpdate);
		_controller?.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final c = _controller;

		// Show black while the controller is loading or if init failed.
		if (c == null || !c.value.isInitialized) {
			return const ColoredBox(color: Colors.black);
		}

		// AspectRatio is the canonical video_player approach — it is always
		// correct once isInitialized=true and avoids the 0×0 invisible-player
		// issue that occurs when using c.value.size.width/height directly.
		return ColoredBox(
			color: Colors.black,
			child: Center(
				child: AspectRatio(
					aspectRatio: c.value.aspectRatio,
					child: VideoPlayer(c),
				),
			),
		);
	}
}
