import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'screens/secondary_player_app.dart';
import 'screens/splash_screen.dart';
import 'services/screenshot_service.dart';

void main() {
	WidgetsFlutterBinding.ensureInitialized();
	runApp(const TheadbookPlayerApp());
}

/// Entry point for the secondary (HDMI/presentation) display engine.
///
/// Called by [FlutterPresentationDisplay.showSecondaryDisplay] when a second
/// physical screen is connected. Runs in its own Flutter engine and isolate —
/// it does NOT share state with [main] but DOES share the on-disk media cache.
///
/// The function name 'secondaryDisplayMain' must exactly match the [routerName]
/// passed to [showSecondaryDisplay] in DisplayManagerService.
@pragma('vm:entry-point')
void secondaryDisplayMain() {
	WidgetsFlutterBinding.ensureInitialized();
	runApp(const SecondaryPlayerApp());
}

class TheadbookPlayerApp extends StatelessWidget {
	const TheadbookPlayerApp({super.key});

	@override
	Widget build(BuildContext context) {
		return MaterialApp(
			title: 'theadbook Player',
			debugShowCheckedModeBanner: false,
			theme: ThemeData(
				brightness: Brightness.dark,
				scaffoldBackgroundColor: AppConfig.background,
				colorScheme: const ColorScheme.dark(
					surface: AppConfig.background,
					primary: AppConfig.accentOrange,
				),
			),
			builder: (context, child) {
				return RepaintBoundary(
					key: ScreenshotService.instance.repaintBoundaryKey,
					child: child ?? const SizedBox.shrink(),
				);
			},
			home: const SplashScreen(),
		);
	}
}
