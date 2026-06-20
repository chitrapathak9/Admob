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
	Timer? _watchdog;

	@override
	void initState() {
		super.initState();
		_init();
	}

	Future<void> _init() async {
		final file = File(widget.localPath);

		if (!file.existsSync()) {
			debugPrint('[VideoSlide] ❌ File not found: ${widget.localPath}');
			_startSlotTimer();
			return;
		}

		final fileSize = file.lengthSync();
		if (fileSize == 0) {
			debugPrint('[VideoSlide] ❌ File is empty: ${widget.localPath}');
			_startSlotTimer();
			return;
		}

		debugPrint('[VideoSlide] 📁 File OK: ${widget.localPath} ($fileSize bytes)');

		VideoPlayerController? ctrl;
		try {
			ctrl = VideoPlayerController.file(file);
			debugPrint('[VideoSlide] ⏳ Calling initialize()...');
			await ctrl.initialize();
			debugPrint('[VideoSlide] ✅ initialize() done — isInitialized=${ctrl.value.isInitialized}');

			if (!mounted) {
				debugPrint('[VideoSlide] ⚠️ Widget unmounted during init');
				await ctrl.dispose();
				return;
			}

			if (!ctrl.value.isInitialized) {
				debugPrint('[VideoSlide] ❌ isInitialized is false after initialize()');
				await ctrl.dispose();
				_startSlotTimer();
				return;
			}

			debugPrint(
				'[VideoSlide] 📐 Video info: '
				'duration=${ctrl.value.duration} '
				'size=${ctrl.value.size} '
				'aspectRatio=${ctrl.value.aspectRatio}'
			);

			await ctrl.setLooping(true);
			await ctrl.setVolume(1.0);

			// ──────────────────────────────────────────────────────────────────
			// STRATEGY: Call play() BEFORE putting the VideoPlayer widget into
			// the tree. This tells ExoPlayer to start decoding and buffering
			// frames internally. When Flutter renders the VideoPlayer widget on
			// the next frame and attaches the SurfaceTexture, ExoPlayer will
			// immediately start pushing buffered frames to the surface.
			//
			// This is the approach used by the official video_player examples
			// and avoids the race condition where addPostFrameCallback might
			// fire too late or be skipped.
			// ──────────────────────────────────────────────────────────────────
			debugPrint('[VideoSlide] ▶️ Calling play() (before widget tree)...');
			await ctrl.play();
			debugPrint('[VideoSlide] ▶️ play() returned — isPlaying=${ctrl.value.isPlaying}');

			if (!mounted) {
				debugPrint('[VideoSlide] ⚠️ Widget unmounted after play()');
				await ctrl.dispose();
				return;
			}

			ctrl.addListener(_onControllerUpdate);

			// Now insert the VideoPlayer widget into the tree.
			setState(() => _controller = ctrl);

			// Start the slot duration timer only after playback is initiated.
			_startSlotTimer();

			// Install a watchdog: if after 3 seconds the video is still not
			// playing, try seekTo(0) + play() which resets ExoPlayer's decoder
			// pipeline. This handles edge cases on certain Android OEMs.
			_watchdog = Timer(const Duration(seconds: 3), () {
				_checkAndRetryPlayback();
			});
		} catch (e, st) {
			debugPrint('[VideoSlide] ❌ Init/play failed: $e\n$st');
			await ctrl?.dispose();
			_startSlotTimer();
		}
	}

	void _checkAndRetryPlayback() async {
		if (!mounted || _completed) return;
		final c = _controller;
		if (c == null || !c.value.isInitialized) return;

		if (!c.value.isPlaying) {
			debugPrint('[VideoSlide] 🔁 Watchdog: NOT playing after 3s — retry with seek+play');
			try {
				await c.seekTo(Duration.zero);
				await c.play();
				debugPrint('[VideoSlide] 🔁 Watchdog play() returned — isPlaying=${c.value.isPlaying}');
			} catch (e) {
				debugPrint('[VideoSlide] 🔁 Watchdog retry failed: $e');
			}
		} else {
			debugPrint('[VideoSlide] ✅ Watchdog: video IS playing — all good');
		}
	}

	void _startSlotTimer() {
		_durationTimer?.cancel();
		final seconds = widget.duration > 0 ? widget.duration : 30;
		_durationTimer = Timer(Duration(seconds: seconds), _finish);
	}

	void _onControllerUpdate() {
		if (_completed || _controller == null) return;
		final c = _controller!;
		if (c.value.hasError) {
			debugPrint('[VideoSlide] ❌ Playback error: ${c.value.errorDescription}');
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
		_watchdog?.cancel();
		_controller?.removeListener(_onControllerUpdate);
		_controller?.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final c = _controller;

		// Black placeholder while loading or if init failed.
		if (c == null || !c.value.isInitialized) {
			return const SizedBox.expand(child: ColoredBox(color: Colors.black));
		}

		// SizedBox.expand ensures the video fills the entire parent (Stack child).
		return SizedBox.expand(
			child: ColoredBox(
				color: Colors.black,
				child: Center(
					child: AspectRatio(
						aspectRatio: c.value.aspectRatio,
						child: VideoPlayer(c),
					),
				),
			),
		);
	}
}
