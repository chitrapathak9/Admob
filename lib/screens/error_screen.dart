import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../core/player_controller.dart';
import '../widgets/diagnostics_dialog.dart';
import '../widgets/theadbook_logo.dart';

/// Error screen (Phase F2.7). Dumb: shows the controller's error message and
/// auto-retry countdown; buttons call back into the controller.
class ErrorScreen extends StatelessWidget {
  final PlayerController controller;
  const ErrorScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final countdown = controller.errorRetryCountdown;
        return Scaffold(
          backgroundColor: AppConstants.background,
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const TheadbookLogo(height: 90),
                    const SizedBox(height: 32),
                    const Text(
                      'Something went wrong',
                      style: TextStyle(color: Colors.white, fontSize: 22),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      controller.errorMessage ?? 'Unexpected error',
                      style: const TextStyle(color: Colors.white38, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      countdown > 0 ? 'Retrying in $countdown seconds…' : 'Retrying…',
                      style: const TextStyle(color: Colors.white54, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: controller.retryNow,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppConstants.accentOrange,
                          foregroundColor: Colors.black,
                        ),
                        child: const Text('Retry Now', style: TextStyle(fontSize: 18)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => showDiagnosticsDialog(context, controller),
                          child: const Text('Diagnostics', style: TextStyle(color: Colors.white54)),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: controller.reconfigure,
                          child: const Text('Reconfigure', style: TextStyle(color: Colors.white54)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
