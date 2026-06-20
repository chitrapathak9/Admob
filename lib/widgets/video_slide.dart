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
	bool _playStarted = false;
	Timer? _durationTimer;
	Timer? _playbackWatchdog;

	@override
	void initState() {
		super.initState();
		_init();
	}

	Future<void> _init() async {
		final file = File(widget.localPath);

		if (!file.existsSync()) {
			debugPrint('[VideoSlide] File not found: ${widget.localPath}');
			_scheduleDurationTimer();
			return;
		}

		// Reject zero-byte files that may result from a failed download.
		final fileSize = file.lengthSync();
		if (fileSize == 0) {
			debugPrint('[VideoSlide] File is empty (0 bytes): ${widget.localPath}');
			_scheduleDurationTimer();
			return;
		}

		debugPrint('[VideoSlide] Initializing controller for: ${widget.localPath} ($fileSize bytes)');

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
				_scheduleDurationTimer();
				return;
			}

			debugPrint(
				'[VideoSlide] OK — duration=${ctrl.value.duration} '
				'size=${ctrl.value.size} aspectRatio=${ctrl.value.aspectRatio}',
			);

			await ctrl.setLooping(true);
			ctrl.addListener(_onControllerUpdate);

			// Put the VideoPlayer widget into the tree first so that the Android
			// SurfaceTexture is created before play() is called.
			setState(() => _controller = ctrl);

			// Schedule the slot duration timer NOW — after we know the file is valid
			// and the controller is ready. Starting it here (rather than in initState)
			// means the duration counts from first-frame display, not from widget creation.
			_scheduleDurationTimer();

			// Call play() after the next frame so the SurfaceTexture is attached.
			// We use the captured non-nullable `ctrl` to avoid a null-deref if
			// _controller is cleared between frames.
			WidgetsBinding.instance.addPostFrameCallback((_) async {
				if (!mounted || _completed) {
					debugPrint('[VideoSlide] Skipping play — mounted=$mounted _completed=$_completed');
					return;
				}
				await _startPlayback(ctrl!);
			});
		} catch (e, st) {
			debugPrint('[VideoSlide] Init failed: ${widget.localPath}\n$e\n$st');
			await ctrl?.dispose();
			_scheduleDurationTimer();
		}
	}

	/// Starts playback and installs a watchdog that retries once if ExoPlayer
	/// doesn't start rendering within 2 seconds (handles surface-attach delays).
	Future<void> _startPlayback(VideoPlayerController ctrl) async {
		if (_playStarted || _completed || !mounted) return;
		_playStarted = true;

		try {
			debugPrint('[VideoSlide] Calling play()');
			await ctrl.play();
			debugPrint('[VideoSlide] play() returned — isPlaying=${ctrl.value.isPlaying}');
		} catch (e) {
			debugPrint('[VideoSlide] play() threw: $e');
		}

		// Watchdog: if after 2 seconds the video is not actually playing,
		// call play() again. This catches ExoPlayer surface-attach races
		// that the postFrameCallback doesn't fully cover on all Android versions.
		_playbackWatchdog = Timer(const Duration(seconds: 2), () async {
			if (!mounted || _completed) return;
			final c = _controller;
			if (c != null && c.value.isInitialized && !c.value.isPlaying) {
				debugPrint('[VideoSlide] Watchdog: video not playing — retrying play()');
				try {
					await c.play();
				} catch (e) {
					debugPrint('[VideoSlide] Watchdog play() threw: $e');
				}
			}
		});
	}

	/// Schedules the slot-duration timer that advances the playlist.
	void _scheduleDurationTimer() {
		_durationTimer?.cancel();
		final playSeconds = widget.duration > 0 ? widget.duration : 30;
		_durationTimer = Timer(Duration(seconds: playSeconds), _finish);
	}

	void _onControllerUpdate() {
		if (_completed || _controller == null) return;
		final c = _controller!;
		if (c.value.hasError) {
			debugPrint('[VideoSlide] Playback error: ${c.value.errorDescription}');
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
		_playbackWatchdog?.cancel();
		_controller?.removeListener(_onControllerUpdate);
		_controller?.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final c = _controller;

		// Black placeholder while the controller is loading or if init failed.
		if (c == null || !c.value.isInitialized) {
			return const ColoredBox(color: Colors.black);
		}

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
