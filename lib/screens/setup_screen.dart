import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/config_service.dart';
import '../services/storage_service.dart';
import '../services/xmds_service.dart';
import '../utils/device_name.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';
import 'waiting_screen.dart';

class SetupScreen extends StatefulWidget {
	const SetupScreen({super.key});

	@override
	State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
	final _cmsKeyController = TextEditingController();
	final _screenNameController = TextEditingController();
	bool _loading = false;
	String? _error;

	@override
	void initState() {
		super.initState();
		_loadDeviceName();
	}

	Future<void> _loadDeviceName() async {
		_screenNameController.text = await defaultDisplayName();
	}

	@override
	void dispose() {
		_cmsKeyController.dispose();
		_screenNameController.dispose();
		super.dispose();
	}

	Future<void> _connect() async {
		final cmsKey = _cmsKeyController.text.trim();
		final screenName = _screenNameController.text.trim();

		if (cmsKey.isEmpty || screenName.isEmpty) {
			setState(() => _error = 'Please enter CMS Key and Screen Name');
			return;
		}

		setState(() {
			_loading = true;
			_error = null;
		});

		try {
			final config = await ConfigService.instance.fetchConfig();
			if (config.cmsKey != cmsKey) {
				throw Exception('CMS Key does not match server configuration');
			}

			await StorageService.instance.saveUserCmsKey(cmsKey);
			await StorageService.instance.saveDisplayName(screenName);
			await StorageService.instance.getOrCreateHardwareKey();

			await XmdsService.instance.registerDisplay(screenName);

			if (!mounted) return;
			Navigator.of(context).pushReplacement(
				MaterialPageRoute<void>(builder: (_) => const WaitingScreen()),
			);
		} catch (e) {
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
										'Connect this screen to theadbook',
										style: TextStyle(color: Colors.white, fontSize: titleSize),
										textAlign: TextAlign.center,
									),
									const SizedBox(height: 40),
									_buildField(
										label: 'CMS Key',
										controller: _cmsKeyController,
									),
									const SizedBox(height: 20),
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
												: const Text('Connect Screen', style: TextStyle(fontSize: 18)),
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

	Widget _buildField({required String label, required TextEditingController controller}) {
		return TextField(
			controller: controller,
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
