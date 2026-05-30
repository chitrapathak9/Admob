import 'package:flutter/material.dart';

import 'config/app_config.dart';
import 'screens/splash_screen.dart';

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
			home: const SplashScreen(),
		);
	}
}
