import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../utils/app_logger.dart';
import 'screen_service.dart';
import 'storage_service.dart';

/// Captures the current app display and uploads it when the server requests one.
class ScreenshotService {
	ScreenshotService._();
	static final ScreenshotService instance = ScreenshotService._();

	final GlobalKey repaintBoundaryKey = GlobalKey();
	bool _capturing = false;

	Future<void> captureAndUpload({String? requestId}) async {
		if (_capturing) {
			AppLogger.screenshotEvent('Capture skipped — already in progress');
			return;
		}

		_capturing = true;
		try {
			await _waitForNextFrame();
			AppLogger.screenshotEvent('Step 2 — taking screenshot of current display');

			final pngBytes = await _capturePng();
			if (pngBytes == null) {
				AppLogger.screenshotEvent('Step 2 FAILED — could not capture display');
				return;
			}

			AppLogger.screenshotEvent('Step 2 OK — captured ${pngBytes.length} bytes PNG');
			final hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
			await ScreenService.instance.uploadScreenshot(
				hardwareKey: hardwareKey,
				pngBytes: pngBytes,
				requestId: requestId,
			);
		} catch (e, st) {
			AppLogger.screenApiError('captureAndUpload failed', e, st);
		} finally {
			_capturing = false;
		}
	}

	Future<void> _waitForNextFrame() async {
		final completer = Completer<void>();
		WidgetsBinding.instance.addPostFrameCallback((_) {
			if (!completer.isCompleted) completer.complete();
		});
		WidgetsBinding.instance.scheduleFrame();
		return completer.future;
	}

	Future<Uint8List?> _capturePng() async {
		final boundary = repaintBoundaryKey.currentContext?.findRenderObject()
			as RenderRepaintBoundary?;
		if (boundary == null) return null;

		final pixelRatio =
			WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
		final image = await boundary.toImage(pixelRatio: pixelRatio);
		final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
		return byteData?.buffer.asUint8List();
	}
}
