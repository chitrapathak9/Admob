import 'dart:io';

import 'package:dio/dio.dart';
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
import '../widgets/permission_flow_dialog.dart';
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
		if (mounted) setState(() {});
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
			setState(() => _error = 'Please enter a display name.');
			return;
		}
		if (screenName.length < 2) {
			setState(() => _error = 'Display name must be at least 2 characters.');
			return;
		}
		if (apiUrl.isEmpty) {
			setState(() => _error = 'Please enter a server address.');
			return;
		}
		if (!_isValidServerUrl(apiUrl)) {
			setState(() => _error = 'Please enter a valid server URL (e.g. https://your-server.com).');
			return;
		}

		// Run the step-by-step permission flow (explanation → battery → wakelock → summary).
		// Returns null if the user cancelled at the explanation screen.
		// Returns a PermissionResult if they completed the flow (granted or denied — either way we proceed).
		final permResult = await showPermissionFlowDialog(context);
		if (permResult == null || !mounted) return;

		// Persist always-on display preference (wakelock was already enabled inside the dialog).
		await StorageService.instance.setAlwaysOnDisplay(permResult.wakelockEnabled);

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
					_error = _humanReadableError(e);
					_loading = false;
				});
			}
		}
	}

	/// Maps raw exceptions to user-friendly error messages so the registration
	/// screen never shows a DioException / SocketException stack trace.
	String _humanReadableError(Object error) {
		if (error is DioException) {
			switch (error.type) {
				case DioExceptionType.connectionTimeout:
				case DioExceptionType.sendTimeout:
					return 'Connection timed out. Please check your internet connection and server address.';
				case DioExceptionType.receiveTimeout:
					return 'Server took too long to respond. Please try again.';
				case DioExceptionType.connectionError:
					final inner = error.error;
					if (inner is SocketException) {
						return _socketMessage(inner);
					}
					return 'Unable to reach the server. Please check your internet connection and server address.';
				case DioExceptionType.badResponse:
					final code = error.response?.statusCode;
					if (code == 404) {
						return 'Server endpoint not found (404). Please verify the server address.';
					}
					if (code == 500 || code == 502 || code == 503) {
						return 'Server error ($code). Please try again later.';
					}
					return 'Server returned an unexpected response ($code).';
				default:
					break;
			}
			// Catch-all for DioException variants we didn't match explicitly.
			final inner = error.error;
			if (inner is SocketException) {
				return _socketMessage(inner);
			}
			return error.message ?? 'Network error. Please check your connection.';
		}

		if (error is SocketException) {
			return _socketMessage(error);
		}

		// Strip the leading "Exception: " prefix that Dart adds.
		return error.toString().replaceFirst('Exception: ', '');
	}

	/// Validates that [url] looks like a usable http/https server address.
	static bool _isValidServerUrl(String url) {
		try {
			final uri = Uri.parse(url);
			if (uri.scheme != 'http' && uri.scheme != 'https') return false;
			if (uri.host.isEmpty) return false;
			// Host must contain at least one dot (or be localhost / an IP).
			if (!uri.host.contains('.') &&
				uri.host != 'localhost' &&
				!RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(uri.host)) {
				return false;
			}
			return true;
		} catch (_) {
			return false;
		}
	}

	static String _socketMessage(SocketException e) {
		final msg = e.message.toLowerCase();
		if (msg.contains('no route to host') ||
			msg.contains('network is unreachable') ||
			msg.contains('no address associated') ||
			msg.contains('failed host lookup')) {
			return 'No internet connection. Please check your network settings.';
		}
		if (msg.contains('connection refused')) {
			return 'Server refused the connection. Please verify the server address and ensure it is running.';
		}
		return 'Unable to reach the server. Please check your internet connection and server address.';
	}

	@override
	Widget build(BuildContext context) {
		final padding = adaptiveScreenPadding(context);
		final logoHeight = adaptiveLogoHeightOriented(context, portrait: 100, landscape: 56);
		final titleSize = adaptiveTitleSize(context);
		final afterLogo = adaptiveGap(context, portrait: 32, landscape: 12);
		final afterSubtitle = adaptiveGap(context, portrait: 40, landscape: 16);

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
									SizedBox(height: afterLogo),
									Text(
										'Device Registration',
										style: TextStyle(color: Colors.white, fontSize: titleSize),
										textAlign: TextAlign.center,
									),
									const SizedBox(height: 12),
									const Text(
										'Enter your server address and a name for this display to link it to the signage network.',
										style: TextStyle(color: Colors.white54, fontSize: 14),
										textAlign: TextAlign.center,
									),
									SizedBox(height: afterSubtitle),
									_buildField(
										label: 'CMS Server URL',
										controller: _apiUrlController,
										keyboardType: TextInputType.url,
									),
									const SizedBox(height: 16),
									_buildField(
										label: 'Display Name',
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
									SizedBox(height: adaptiveGap(context, portrait: 32, landscape: 12)),
									SizedBox(
										width: double.infinity,
										height: 52,
										child: ElevatedButton(
											onPressed: _loading ? null : _connect,
											style: ElevatedButton.styleFrom(
												backgroundColor: AppConfig.accentOrange,
												foregroundColor: Colors.white,
											),
											child: _loading
												? const SizedBox(
													width: 24,
													height: 24,
													child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
												)
												: const Text('Register Device', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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
					borderSide: const BorderSide(color: Colors.white24),
					borderRadius: BorderRadius.circular(8),
				),
				focusedBorder: OutlineInputBorder(
					borderSide: const BorderSide(color: AppConfig.accentOrange),
					borderRadius: BorderRadius.circular(8),
				),
			),
		);
	}
}
