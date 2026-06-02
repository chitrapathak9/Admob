import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../services/storage_service.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';
import 'player_screen.dart';
import 'setup_screen.dart';
import 'waiting_screen.dart';

class SplashScreen extends StatefulWidget {
	const SplashScreen({super.key});

	@override
	State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
	@override
	void initState() {
		super.initState();
		_navigate();
	}

	Future<void> _navigate() async {
		await Future<void>.delayed(const Duration(seconds: AppConfig.splashDelaySeconds));
		if (!mounted) return;

		final storage = StorageService.instance;
		final approved = await storage.isApproved();
		final pendingRegistration = await storage.hasPendingRegistration();

		Widget next;
		if (approved) {
			next = const PlayerScreen();
		} else if (pendingRegistration) {
			next = const WaitingScreen();
		} else {
			next = const SetupScreen();
		}

		if (!mounted) return;
		Navigator.of(context).pushReplacement(
			MaterialPageRoute<void>(builder: (_) => next),
		);
	}

	@override
	Widget build(BuildContext context) {
		return Scaffold(
			backgroundColor: AppConfig.background,
			body: Center(child: TheadbookLogo(height: adaptiveLogoHeight(context, large: 160, small: 100))),
		);
	}
}
