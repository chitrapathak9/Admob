import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'screens/splash_screen.dart';
import 'services/screenshot_service.dart';

void main() {
	WidgetsFlutterBinding.ensureInitialized();
	runApp(const TheadbookPlayerApp());
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
