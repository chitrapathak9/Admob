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
		// Advance after the scheduled duration. The video loops within that window
		// so a 10 s clip scheduled for 30 s plays three times.
		final playSeconds = widget.duration > 0 ? widget.duration : 30;
		_durationTimer = Timer(Duration(seconds: playSeconds), _finish);
		_init();
	}

	Future<void> _init() async {
		try {
			_controller = VideoPlayerController.file(File(widget.localPath));
			await _controller!.initialize();
			await _controller!.setLooping(true);
			_controller!.addListener(_onTick);
			await _controller!.play();
			if (mounted) setState(() {});
		} catch (e) {
			debugPrint('[VideoSlide] Init failed: $e');
			_finish();
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
		if (c == null || !c.value.isInitialized) {
			return const ColoredBox(color: Colors.black);
		}
		return ColoredBox(
			color: Colors.black,
			child: SizedBox.expand(
				child: FittedBox(
					// BoxFit.contain keeps the video's native aspect ratio.
					// Black bars appear when the screen and video orientations differ
					// rather than cropping the content.
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
