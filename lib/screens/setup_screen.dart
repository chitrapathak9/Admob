import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../models/screen_connect_data.dart';
import '../services/api_url_service.dart';
import '../services/screen_service.dart';
import '../services/storage_service.dart';
import '../services/xmds_service.dart';
import '../utils/app_logger.dart';
import '../utils/device_name.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';
import 'player_screen.dart';
import 'waiting_screen.dart';

class SetupScreen extends StatefulWidget {
	const SetupScreen({super.key});

	@override
	State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
	final _screenNameController = TextEditingController();
	final _apiUrlController = TextEditingController();
	bool _loading = false;
	String? _error;

	@override
	void initState() {
		super.initState();
		_loadInitialValues();
	}

	Future<void> _loadInitialValues() async {
		final storage = StorageService.instance;
		final savedApiUrl = await storage.loadApiBaseUrl();
		_apiUrlController.text = savedApiUrl ?? AppConfig.defaultBaseUrl;
		_screenNameController.text = await defaultDisplayName();
	}

	@override
	void dispose() {
		_screenNameController.dispose();
		_apiUrlController.dispose();
		super.dispose();
	}

	Future<ScreenConnectData> _connectWithRetry({
		required String hardwareKey,
		required String screenName,
	}) async {
		Object? lastError;
		for (var attempt = 0; attempt < AppConfig.connectMaxRetries; attempt++) {
			AppLogger.setup('Connect attempt ${attempt + 1}/${AppConfig.connectMaxRetries}');
			try {
				return await ScreenService.instance.connect(
					hardwareKey: hardwareKey,
					deviceName: screenName,
				);
			} catch (e, st) {
				lastError = e;
				AppLogger.setupError('Connect attempt ${attempt + 1} failed', e, st);
				if (attempt < AppConfig.connectMaxRetries - 1) {
					AppLogger.setup('Retrying in ${AppConfig.connectRetrySeconds}s…');
					await Future<void>.delayed(
						const Duration(seconds: AppConfig.connectRetrySeconds),
					);
				}
			}
		}
		throw lastError ?? Exception('Screen connect failed');
	}

	Future<void> _connect() async {
		final screenName = _screenNameController.text.trim();
		final apiUrl = _apiUrlController.text.trim();

		if (screenName.isEmpty) {
			setState(() => _error = 'Please enter a screen name');
			return;
		}
		if (apiUrl.isEmpty) {
			setState(() => _error = 'Please enter a server address');
			return;
		}

		setState(() {
			_loading = true;
			_error = null;
		});

		try {
			await ApiUrlService.instance.setBaseUrl(apiUrl);

			final storage = StorageService.instance;
			final hardwareKey = await storage.getOrCreateHardwareKey();

			AppLogger.setup('Starting registration for "$screenName" hardwareKey=$hardwareKey');

			final connectResult = await _connectWithRetry(
				hardwareKey: hardwareKey,
				screenName: screenName,
			);

			AppLogger.setup('Connect succeeded — saving credentials (status=${connectResult.status})');
			await storage.saveDisplayName(screenName);
			await storage.saveConnectResult(connectResult);
			await storage.setApproved(connectResult.status == 'approved');

			AppLogger.setup('Calling XMDS RegisterDisplay…');
			final registerResult = await XmdsService.instance.registerDisplay(screenName);
			AppLogger.setup(
				'RegisterDisplay finished: code=${registerResult.code} message="${registerResult.message}"',
			);

			if (!mounted) return;
			final next = connectResult.status == 'approved'
				? const PlayerScreen()
				: const WaitingScreen();
			AppLogger.setup('Navigating to ${connectResult.status == 'approved' ? 'PlayerScreen' : 'WaitingScreen'}');
			Navigator.of(context).pushReplacement(
				MaterialPageRoute<void>(builder: (_) => next),
			);
		} catch (e, st) {
			AppLogger.setupError('Registration flow failed', e, st);
			if (mounted) {
				setState(() {
					_error = e.toString().replaceFirst('Exception: ', '');
					_loading = false;
				});
			}
		}
	}

	@override
	Widget build(BuildContext context) {
		final padding = adaptiveScreenPadding(context);
		final logoHeight = adaptiveLogoHeight(context, large: 100, small: 72);
		final titleSize = adaptiveTitleSize(context);

		return Scaffold(
			backgroundColor: AppConfig.background,
			resizeToAvoidBottomInset: true,
			body: SafeArea(
				child: Center(
					child: SingleChildScrollView(
						padding: padding,
						keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
						child: ConstrainedBox(
							constraints: const BoxConstraints(maxWidth: 520),
							child: Column(
								mainAxisAlignment: MainAxisAlignment.center,
								children: [
									TheadbookLogo(height: logoHeight),
									const SizedBox(height: 32),
									Text(
										'Connect Your Screen',
										style: TextStyle(color: Colors.white, fontSize: titleSize),
										textAlign: TextAlign.center,
									),
									const SizedBox(height: 12),
									const Text(
										'Enter the details below to connect this screen to your account.',
										style: TextStyle(color: Colors.white54, fontSize: 14),
										textAlign: TextAlign.center,
									),
									const SizedBox(height: 40),
									_buildField(
										label: 'Server Address',
										controller: _apiUrlController,
										keyboardType: TextInputType.url,
									),
									const SizedBox(height: 16),
									_buildField(
										label: 'Screen Name',
										controller: _screenNameController,
									),
									if (_error != null) ...[
										const SizedBox(height: 16),
										Text(
											_error!,
											style: const TextStyle(color: Colors.redAccent),
											textAlign: TextAlign.center,
										),
									],
									const SizedBox(height: 32),
									SizedBox(
										width: double.infinity,
										height: 52,
										child: ElevatedButton(
											onPressed: _loading ? null : _connect,
											style: ElevatedButton.styleFrom(
												backgroundColor: AppConfig.accentOrange,
												foregroundColor: Colors.black,
											),
											child: _loading
												? const SizedBox(
													width: 24,
													height: 24,
													child: CircularProgressIndicator(strokeWidth: 2),
												)
												: const Text('Continue', style: TextStyle(fontSize: 18)),
										),
									),
								],
							),
						),
					),
				),
			),
		);
	}

	Widget _buildField({
		required String label,
		required TextEditingController controller,
		TextInputType keyboardType = TextInputType.text,
	}) {
		return TextField(
			controller: controller,
			keyboardType: keyboardType,
			style: const TextStyle(color: Colors.white),
			decoration: InputDecoration(
				labelText: label,
				labelStyle: const TextStyle(color: Colors.white54),
				enabledBorder: OutlineInputBorder(
					borderSide: BorderSide(color: Colors.white24),
					borderRadius: BorderRadius.circular(8),
				),
				focusedBorder: OutlineInputBorder(
					borderSide: BorderSide(color: AppConfig.accentOrange),
					borderRadius: BorderRadius.circular(8),
				),
			),
		);
	}
}
