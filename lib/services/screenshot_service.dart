import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import '../utils/app_logger.dart';
import 'display_manager_service.dart';
import 'screen_service.dart';
import 'storage_service.dart';

/// Captures the current app display and uploads it when the server requests one.
class ScreenshotService {
	ScreenshotService._();
	static final ScreenshotService instance = ScreenshotService._();

	final GlobalKey repaintBoundaryKey = GlobalKey();
	bool _capturing = false;

	/// [displayTarget]: 'primary' (default) | 'secondary' (PHOENIX dual-display only).
	Future<void> captureAndUpload({String? requestId, String displayTarget = 'primary'}) async {
		if (_capturing) {
			AppLogger.screenshotEvent('Capture skipped — already in progress');
			return;
		}

		_capturing = true;
		try {
			if (displayTarget == 'secondary') {
				await _captureSecondaryAndUpload(requestId: requestId);
			} else {
				await _capturePrimaryAndUpload(requestId: requestId);
			}
		} finally {
			_capturing = false;
		}
	}

	Future<void> _capturePrimaryAndUpload({String? requestId}) async {
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
			AppLogger.screenApiError('captureAndUpload (primary) failed', e, st);
		}
	}

	Future<void> _captureSecondaryAndUpload({String? requestId}) async {
		final dm = DisplayManagerService.instance;
		if (!dm.secondaryActive) {
			AppLogger.screenshotEvent('Secondary screenshot skipped — secondary display not active');
			return;
		}

		try {
			AppLogger.screenshotEvent('Step 2 — requesting screenshot from secondary display engine');
			final filePath = await dm.requestSecondaryScreenshot(requestId);
			if (filePath == null) {
				AppLogger.screenshotEvent('Step 2 FAILED — secondary screenshot timed out or errored');
				return;
			}

			AppLogger.screenshotEvent('Step 2 OK — secondary screenshot at $filePath');
			final file = File(filePath);
			final pngBytes = await file.readAsBytes();

			final hardwareKey = await StorageService.instance.getOrCreateHardwareKey();
			await ScreenService.instance.uploadScreenshot(
				hardwareKey: hardwareKey,
				pngBytes: pngBytes,
				requestId: requestId,
			);

			// Clean up the temp file written by the secondary engine.
			await file.delete().catchError((_) => file);
			AppLogger.screenshotEvent('Step 3 DONE — secondary screenshot uploaded and temp file deleted');
		} catch (e, st) {
			AppLogger.screenApiError('captureAndUpload (secondary) failed', e, st);
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
