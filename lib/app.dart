import 'package:flutter/material.dart';

import 'config/app_constants.dart';
import 'core/player_controller.dart';
import 'core/state_machine.dart';
import 'screens/error_screen.dart';
import 'screens/no_content_screen.dart';
import 'screens/player_screen.dart';
import 'screens/setup_screen.dart';
import 'screens/splash_screen.dart';
import 'screens/waiting_screen.dart';

/// Root app (Phase F2.1). Owns the single [PlayerController] and routes screens
/// purely from `controller.uiScreen` — the controller is the only thing with logic.
class TheadbookPlayerApp extends StatefulWidget {
  const TheadbookPlayerApp({super.key});

  @override
  State<TheadbookPlayerApp> createState() => _TheadbookPlayerAppState();
}

class _TheadbookPlayerAppState extends State<TheadbookPlayerApp> {
  late final PlayerController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PlayerController();
    // Show the splash briefly, then let the controller drive everything.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(seconds: AppConstants.splashDelaySeconds));
      await _controller.initialize();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'theadbook Player',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppConstants.background,
        colorScheme: const ColorScheme.dark(
          surface: AppConstants.background,
          primary: AppConstants.accentOrange,
        ),
      ),
      home: PlayerRoot(controller: _controller),
    );
  }
}

/// Switches the visible screen based on the state machine. Kiosk mode blocks
/// back navigation app-wide via [PopScope].
class PlayerRoot extends StatelessWidget {
  final PlayerController controller;
  const PlayerRoot({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          switch (controller.uiScreen) {
            case UiScreen.splash:
              return const SplashScreen();
            case UiScreen.setup:
              return SetupScreen(controller: controller);
            case UiScreen.waiting:
              return WaitingScreen(controller: controller);
            case UiScreen.player:
              return PlayerScreen(controller: controller);
            case UiScreen.noContent:
              return NoContentScreen(controller: controller);
            case UiScreen.error:
              return ErrorScreen(controller: controller);
          }
        },
      ),
    );
  }
}
