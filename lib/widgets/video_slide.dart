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
		// Duration timer drives playlist advancement regardless of video length.
		// A 10 s clip scheduled for 30 s loops three times, then we move on.
		final playSeconds = widget.duration > 0 ? widget.duration : 30;
		_durationTimer = Timer(Duration(seconds: playSeconds), _finish);
		_init();
	}

	Future<void> _init() async {
		final file = File(widget.localPath);

		// Guard: file must exist before handing it to ExoPlayer.
		if (!file.existsSync()) {
			debugPrint('[VideoSlide] File not found: ${widget.localPath}');
				_finish();
			return;
		}

		VideoPlayerController? ctrl;
		try {
			ctrl = VideoPlayerController.file(file);
			await ctrl.initialize();
			await ctrl.setLooping(true);
			ctrl.addListener(_onTick);

			if (!mounted) {
				await ctrl.dispose();
				return;
			}

			await ctrl.play();
			setState(() => _controller = ctrl);
		} catch (e, st) {
			debugPrint('[VideoSlide] Init failed path=${widget.localPath}: $e');
			debugPrint('[VideoSlide] Stack: $st');
			await ctrl?.dispose();
				// Let the duration timer call _finish naturally so the slot isn't skipped
			// instantly — the black frame plays out the remaining scheduled duration.
		}
	}

	void _onTick() {
		if (_completed || _controller == null) return;
		if (_controller!.value.hasError) {
			debugPrint('[VideoSlide] Playback error: ${_controller!.value.errorDescription}');
			_finish();
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
		_controller?.removeListener(_onTick);
		_controller?.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final c = _controller;

		// Initialising or failed — show a plain black frame.
		// On failure the duration timer will advance the playlist at the right time.
		if (c == null || !c.value.isInitialized) {
			return const ColoredBox(color: Colors.black);
		}

		return ColoredBox(
			color: Colors.black,
			child: SizedBox.expand(
				child: FittedBox(
					// BoxFit.contain preserves the video's native aspect ratio.
					fit: BoxFit.contain,
					child: SizedBox(
						width: c.value.size.width,
						height: c.value.size.height,
						child: VideoPlayer(c),
					),
				),
			),
		);
	}
}
