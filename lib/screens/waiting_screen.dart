import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/screen_status_data.dart';
import '../services/screen_service.dart';
import '../services/storage_service.dart';
import '../utils/app_logger.dart';
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
	Timer? _pollTimer;
	String _hardwareKey = '';
	String _statusMessage = 'Waiting for admin approval…';
	String? _error;
	bool _polling = false;

	@override
	void initState() {
		super.initState();
		_init();
	}

	Future<void> _init() async {
		final hardwareKey = await StorageService.instance.loadHardwareKey();
		if (!mounted) return;
		setState(() => _hardwareKey = hardwareKey ?? '');

		if (hardwareKey == null || hardwareKey.isEmpty) {
			setState(() => _error = 'Hardware key missing. Use Reconfigure.');
			return;
		}

		await _pollStatus();
		_startPollTimer();
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
					setState(() => _error = 'Missing registration data. Use Reconfigure.');
				}
				return;
			}

			AppLogger.status('Polling status for hardwareKey=$hardwareKey');
			final status = await ScreenService.instance.getStatus(hardwareKey);
			if (!mounted) return;

			await storage.saveRegistrationStatus(status.status);

			if (status.isApproved) {
				AppLogger.status('Approved — navigating to PlayerScreen');
				_pollTimer?.cancel();
				await storage.setApproved(true);
				if (!mounted) return;
				Navigator.of(context).pushReplacement(
					MaterialPageRoute<void>(builder: (_) => const PlayerScreen()),
				);
				return;
			}

			if (status.isExpired) {
				AppLogger.status('Expired — stopping poll');
				_pollTimer?.cancel();
				setState(() {
					_statusMessage = status.message;
					_error = 'Registration expired. Reconnect to register again.';
				});
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
						if (reconnect.status == 'approved') {
							_pollTimer?.cancel();
							await storage.setApproved(true);
							if (!mounted) return;
							Navigator.of(context).pushReplacement(
								MaterialPageRoute<void>(builder: (_) => const PlayerScreen()),
							);
							return;
						}
					} catch (_) {}
				}
			}

			if (status.isProcessing) {
				setState(() {
					_statusMessage = _messageForStatus(status);
					_error = null;
				});
				return;
			}

			setState(() {
				_statusMessage = _messageForStatus(status);
				_error = null;
			});
		} catch (e, st) {
			AppLogger.status('Poll failed: $e');
			debugPrint('[Status] stack: $st');
			if (mounted) {
				setState(() => _error = 'Connection failed. Retrying…');
			}
		} finally {
			_polling = false;
		}
	}

	String _messageForStatus(ScreenStatusData status) {
		if (status.message.isNotEmpty) return status.message;
		switch (status.status) {
			case 'pending':
				return 'Registration request received — completing setup…';
			case 'processing':
				return 'Waiting for admin approval…';
			default:
				return 'Waiting for admin approval…';
		}
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
		_pollTimer?.cancel();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		final padding = adaptiveScreenPadding(context);
		final logoHeight = adaptiveLogoHeight(context);

		return Scaffold(
			backgroundColor: AppConfig.background,
			body: SafeArea(
				child: LayoutBuilder(
					builder: (context, constraints) {
						return SingleChildScrollView(
							padding: padding,
							child: ConstrainedBox(
								constraints: BoxConstraints(minHeight: constraints.maxHeight - padding.vertical),
								child: Column(
									mainAxisAlignment: MainAxisAlignment.center,
									children: [
										TheadbookLogo(height: logoHeight),
										const SizedBox(height: 40),
										const CircularProgressIndicator(color: AppConfig.accentOrange),
										const SizedBox(height: 24),
										Text(
											_statusMessage,
											style: const TextStyle(color: Colors.white, fontSize: 20),
											textAlign: TextAlign.center,
										),
										const SizedBox(height: 32),
										const Text(
											'Hardware Key',
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
										const SizedBox(height: 48),
										TextButton(
											onPressed: _reconfigure,
											child: const Text('Reconfigure', style: TextStyle(color: Colors.white54)),
										),
									],
								),
							),
						);
					},
				),
			),
		);
	}
}
