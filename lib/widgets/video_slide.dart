import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoSlide extends StatefulWidget {
	final String localPath;
	final VoidCallback onComplete;

	const VideoSlide({
		super.key,
		required this.localPath,
		required this.onComplete,
	});

	@override
	State<VideoSlide> createState() => _VideoSlideState();
}

class _VideoSlideState extends State<VideoSlide> {
	VideoPlayerController? _controller;
	bool _completed = false;

	@override
	void initState() {
		super.initState();
		_init();
	}

	Future<void> _init() async {
		try {
			_controller = VideoPlayerController.file(File(widget.localPath));
			await _controller!.initialize();
			_controller!.addListener(_onTick);
			await _controller!.play();
			if (mounted) setState(() {});
		} catch (_) {
			_finish();
		}
	}

	void _onTick() {
		if (_completed || _controller == null) return;
		final value = _controller!.value;
		if (value.position >= value.duration && value.duration > Duration.zero) {
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
					fit: BoxFit.cover,
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
