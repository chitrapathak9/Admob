import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/storage_service.dart';
import '../services/xmds_service.dart';
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

		await _pollRegisterDisplay();
		_startPollTimer();
	}

	void _startPollTimer() async {
		final interval = await StorageService.instance.getCollectionInterval();
		_pollTimer?.cancel();
		_pollTimer = Timer.periodic(Duration(seconds: interval), (_) => _pollRegisterDisplay());
	}

	/// Polls XMDS RegisterDisplay using serverKey, hardwareKey, displayName from SharedPreferences.
	Future<void> _pollRegisterDisplay() async {
		if (_polling) return;
		_polling = true;

		try {
			final storage = StorageService.instance;
			final serverKey = await storage.getCmsKey();
			final hardwareKey = await storage.loadHardwareKey();
			final displayName = await storage.loadDisplayName();

			if (serverKey == null ||
				serverKey.isEmpty ||
				hardwareKey == null ||
				hardwareKey.isEmpty ||
				displayName == null ||
				displayName.isEmpty) {
				if (mounted) {
					setState(() => _error = 'Missing registration data. Use Reconfigure.');
				}
				return;
			}

			// XmdsService RegisterDisplay uses the same SharedPreferences values for SOAP body.
			final result = await XmdsService.instance.registerDisplay(displayName);
			if (!mounted) return;

			if (result.code == 201) {
				_pollTimer?.cancel();
				await storage.setApproved(true);
				if (!mounted) return;
				Navigator.of(context).pushReplacement(
					MaterialPageRoute<void>(builder: (_) => const PlayerScreen()),
				);
				return;
			}

			if (result.code == 200) {
				setState(() => _error = null);
				return;
			}

			setState(() {
				_error = result.message.isNotEmpty
					? result.message
					: 'Unexpected response (code ${result.code}). Retrying…';
			});
		} catch (_) {
			if (mounted) {
				setState(() => _error = 'Connection failed. Retrying…');
			}
		} finally {
			_polling = false;
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
										const Text(
											'Waiting for admin approval…',
											style: TextStyle(color: Colors.white, fontSize: 20),
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
											Text(_error!, style: const TextStyle(color: Colors.white38)),
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
