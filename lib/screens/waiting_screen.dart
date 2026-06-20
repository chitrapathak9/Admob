import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/screen_status_data.dart';
import '../services/screen_service.dart';
import '../services/socket_service.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
import '../utils/device_name.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';
import 'player_screen.dart';
import 'setup_screen.dart';

class WaitingScreen extends StatefulWidget {
	const WaitingScreen({super.key});

	@override
	State<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends State<WaitingScreen> {
	static const _connectedTitle = 'Device Registered Successfully';
	static const _connectedMessage = 
		'This display is pending administrator approval.\n'
		'Playback will begin automatically once authorized in the CMS.';
	static const _connectingTitle = 'Registering Device';
	static const _connectingMessage = 'Please wait while we securely connect this device to the server...';

	Timer? _pollTimer;
	String _hardwareKey = '';
	String _title = _connectedTitle;
	String _message = _connectedMessage;
	String? _error;
	bool _polling = false;

	@override
	void initState() {
		super.initState();
		SocketEventBus.instance.on(SocketEvent.screenApproved, _handleSocketApproval);
		SocketEventBus.instance.on(SocketEvent.deviceNotRegistered, _handleDeviceNotRegistered);
		_init();
	}

	void _handleDeviceNotRegistered(dynamic _) {
		if (!mounted) return;
		unawaited(_reconfigure());
	}

	void _handleSocketApproval(dynamic _) {
		if (!mounted) return;
		AppLogger.status('Socket screen:approved — navigating to PlayerScreen');
		_pollTimer?.cancel();
		_navigateToPlayer();
	}

	Future<void> _navigateToPlayer() async {
		await StorageService.instance.setApproved(true);
		if (!mounted) return;
		Navigator.of(context).pushReplacement(
			MaterialPageRoute<void>(builder: (_) => const PlayerScreen()),
		);
	}

	Future<void> _init() async {
		final hardwareKey = await StorageService.instance.loadHardwareKey();
		if (!mounted) return;
		setState(() => _hardwareKey = hardwareKey ?? '');

		if (hardwareKey == null || hardwareKey.isEmpty) {
			setState(() => _error = 'Screen ID not found. Tap Edit Settings.');
			return;
		}

		await _ensureScreenConnected();
		await _pollStatus();
		_startPollTimer();
	}

	/// Calls POST /api/v1/screens/connect when the device was never registered.
	Future<void> _ensureScreenConnected() async {
		final storage = StorageService.instance;
		final hardwareKey = await storage.loadHardwareKey();
		if (hardwareKey == null || hardwareKey.isEmpty) return;

		final existingDeviceId = await storage.loadDeviceId();
		if (existingDeviceId != null && existingDeviceId.isNotEmpty) return;

		if (mounted) {
			setState(() {
				_title = _connectingTitle;
				_message = _connectingMessage;
				_error = null;
			});
		}

		var displayName = await storage.loadDisplayName();
		if (displayName == null || displayName.isEmpty) {
			displayName = await defaultDisplayName();
			await storage.saveDisplayName(displayName);
		}

		try {
			AppLogger.status('Initiating connect for hardwareKey=$hardwareKey name="$displayName"');
			final connectResult = await ScreenService.instance.connect(
				hardwareKey: hardwareKey,
				deviceName: displayName,
			);
			await storage.saveConnectResult(connectResult);
			AppLogger.status('Connect OK deviceId=${connectResult.deviceId} status=${connectResult.status}');

			if (connectResult.status == 'approved' || connectResult.status == 'active') {
				_pollTimer?.cancel();
				await _navigateToPlayer();
			}
		} catch (e, st) {
			AppLogger.status('Connect failed: $e');
			debugPrint('[Status] connect stack: $st');
			if (mounted) {
				setState(() {
					_error = e.toString().replaceFirst('Exception: ', '');
					_title = _connectingTitle;
					_message = 'Could not connect your screen. Tap Edit Settings to try again.';
				});
			}
		}
	}

	void _startPollTimer() {
		_pollTimer?.cancel();
		_pollTimer = Timer.periodic(
			const Duration(seconds: AppConfig.screenStatusPollSeconds),
			(_) => _pollStatus(),
		);
	}

	Future<void> _pollStatus() async {
		if (_polling) return;
		_polling = true;

		try {
			final storage = StorageService.instance;
			final hardwareKey = await storage.loadHardwareKey();
			if (hardwareKey == null || hardwareKey.isEmpty) {
				AppLogger.status('Poll skipped — hardware key missing');
				if (mounted) {
					setState(() => _error = 'Missing registration data. Tap Edit Settings.');
				}
				return;
			}

			AppLogger.status('Polling status for hardwareKey=$hardwareKey');
			final status = await ScreenService.instance.getStatus(hardwareKey);
			if (!mounted) return;

			await storage.saveRegistrationStatus(status.status);

			if (status.isApprovedOrActive) {
				AppLogger.status('Approved — navigating to PlayerScreen');
				_pollTimer?.cancel();
				await _navigateToPlayer();
				return;
			}

			if (status.isExpired) {
				AppLogger.status('Expired — stopping poll');
				_pollTimer?.cancel();
				setState(() {
					_title = 'Registration Expired';
					_message = 'Your screen registration has expired. Tap Edit Settings to connect again.';
					_error = null;
				});
				return;
			}

			if (status.needsConnectFirst) {
				AppLogger.status('Status requires connect — registering device');
				await _ensureScreenConnected();
				return;
			}

			if (status.isPending) {
				AppLogger.status('Status pending — re-calling connect');
				final displayName = await storage.loadDisplayName();
				if (displayName != null && displayName.isNotEmpty) {
					try {
						final reconnect = await ScreenService.instance.connect(
							hardwareKey: hardwareKey,
							deviceName: displayName,
						);
						await storage.saveConnectResult(reconnect);
						if (reconnect.status == 'approved' || reconnect.status == 'active') {
							_pollTimer?.cancel();
							await _navigateToPlayer();
							return;
						}
					} catch (_) {}
				}
			}

			if (status.isProcessing) {
				setState(() {
					_applyStatusCopy(status);
					_error = null;
				});
				return;
			}

			setState(() {
				_applyStatusCopy(status);
				_error = null;
			});
		} catch (e, st) {
			AppLogger.status('Poll failed: $e');
			debugPrint('[Status] stack: $st');
			if (e is ScreenApiException && e.isNotRegistered) {
				AppLogger.status('Device not registered — returning to connect screen');
				await _reconfigure();
				return;
			}
			if (mounted) {
				setState(() => _error = 'Connection failed. Retrying…');
			}
		} finally {
			_polling = false;
		}
	}

	void _applyStatusCopy(ScreenStatusData status) {
		if (status.needsConnectFirst) {
			_title = _connectingTitle;
			_message = _connectingMessage;
			return;
		}
		_title = _connectedTitle;
		_message = _connectedMessage;
	}

	Future<void> _reconfigure() async {
		_pollTimer?.cancel();
		await StorageService.instance.clearAll();
		if (!mounted) return;
		Navigator.of(context).pushReplacement(
			MaterialPageRoute<void>(builder: (_) => const SetupScreen()),
		);
	}

	@override
	void dispose() {
		SocketEventBus.instance.off(SocketEvent.screenApproved, _handleSocketApproval);
		SocketEventBus.instance.off(SocketEvent.deviceNotRegistered, _handleDeviceNotRegistered);
		_pollTimer?.cancel();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final padding = adaptiveScreenPadding(context);
		final logoHeight = adaptiveLogoHeightOriented(context, portrait: 120, landscape: 56);
		final afterLogo = adaptiveGap(context, portrait: 40, landscape: 16);
		final afterSpinner = adaptiveGap(context, portrait: 24, landscape: 12);
		final beforeId = adaptiveGap(context, portrait: 32, landscape: 12);
		final beforeButton = adaptiveGap(context, portrait: 48, landscape: 16);

		return Scaffold(
			backgroundColor: AppConfig.background,
			body: SafeArea(
				child: Center(
					child: SingleChildScrollView(
						padding: padding,
						child: ConstrainedBox(
							constraints: const BoxConstraints(maxWidth: 520),
							child: Column(
								mainAxisAlignment: MainAxisAlignment.center,
								children: [
									TheadbookLogo(height: logoHeight),
									SizedBox(height: afterLogo),
									const CircularProgressIndicator(color: AppConfig.accentOrange),
									SizedBox(height: afterSpinner),
									Text(
										_title,
										style: const TextStyle(
											color: Colors.white,
											fontSize: 20,
											fontWeight: FontWeight.bold,
										),
										textAlign: TextAlign.center,
									),
									const SizedBox(height: 12),
									Text(
										_message,
										style: const TextStyle(color: Colors.white54, fontSize: 14),
										textAlign: TextAlign.center,
									),
									SizedBox(height: beforeId),
									const Text(
										'Display ID',
										style: TextStyle(color: Colors.white54, fontSize: 14),
									),
									const SizedBox(height: 8),
									SelectableText(
										_hardwareKey,
										style: TextStyle(
											color: AppConfig.accentOrange,
											fontSize: MediaQuery.sizeOf(context).width < 360 ? 14 : 18,
											fontWeight: FontWeight.bold,
											letterSpacing: 1,
										),
										textAlign: TextAlign.center,
									),
									if (_error != null) ...[
										const SizedBox(height: 16),
										Text(_error!, style: const TextStyle(color: Colors.white38), textAlign: TextAlign.center),
									],
									SizedBox(height: beforeButton),
									TextButton(
										onPressed: _reconfigure,
										child: const Text('Reconfigure Device', style: TextStyle(color: Colors.white54)),
									),
								],
							),
						),
					),
				),
			),
		);
	}
}
