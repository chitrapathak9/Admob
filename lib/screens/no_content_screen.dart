import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../core/player_controller.dart';
import '../widgets/diagnostics_dialog.dart';
import '../widgets/theadbook_logo.dart';

/// No-content screen (Phase F2.7). Dumb: the controller's collection timer keeps
/// checking every 60s and switches state when content appears. A barely-visible
/// Diagnostics button surfaces the backend diagnosis on demand.
class NoContentScreen extends StatelessWidget {
  final PlayerController controller;
  const NoContentScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.background,
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    TheadbookLogo(height: 100),
                    SizedBox(height: 40),
                    Text(
                      'No content scheduled',
                      style: TextStyle(color: Colors.white, fontSize: 22),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Content will appear automatically when scheduled',
                      style: TextStyle(color: Colors.white54, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    SizedBox(height: 24),
                    Text(
                      'Checking every 60 seconds…',
                      style: TextStyle(color: Colors.white38, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: TextButton(
                onPressed: () => showDiagnosticsDialog(context, controller),
                child: const Text('Diagnostics', style: TextStyle(color: Colors.white24, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
