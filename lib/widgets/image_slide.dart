import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

class ImageSlide extends StatefulWidget {
	final String localPath;
	final int duration;
	final VoidCallback onComplete;

	const ImageSlide({
		super.key,
		required this.localPath,
		required this.duration,
		required this.onComplete,
	});

	@override
	State<ImageSlide> createState() => _ImageSlideState();
}

class _ImageSlideState extends State<ImageSlide> {
	Timer? _timer;

	@override
	void initState() {
		super.initState();
		_timer = Timer(Duration(seconds: widget.duration), () {
			if (mounted) widget.onComplete();
		});
	}

	@override
	void dispose() {
		_timer?.cancel();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		return ColoredBox(
			color: Colors.black,
			child: Image.file(
				File(widget.localPath),
				// BoxFit.contain preserves the image's native aspect ratio.
				// Black bars appear on the letterbox/pillarbox sides instead of
				// cropping the content when the screen orientation doesn't match.
				fit: BoxFit.contain,
				width: double.infinity,
				height: double.infinity,
				errorBuilder: (context, error, stackTrace) {
					WidgetsBinding.instance.addPostFrameCallback((_) => widget.onComplete());
					return const SizedBox.shrink();
				},
			),
		);
	}
}
