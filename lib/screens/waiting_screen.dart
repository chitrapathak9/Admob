import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../core/player_controller.dart';
import '../core/state_machine.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';

/// Waiting screen (Phase F2.7). Dumb: the controller polls status internally and
/// auto-navigates by changing state. Covers both WAITING (approval) and SYNCING
/// (loading content) — the message adapts from the controller's state.
class WaitingScreen extends StatelessWidget {
  final PlayerController controller;
  const WaitingScreen({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final padding = adaptiveScreenPadding(context);
    final logoHeight = adaptiveLogoHeight(context);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final syncing = controller.currentState == PlayerState.syncing;
        final message = syncing ? 'Loading content…' : 'Waiting for admin approval…';

        return Scaffold(
          backgroundColor: AppConstants.background,
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return SingleChildScrollView(
                  padding: padding,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight - padding.vertical),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TheadbookLogo(height: logoHeight),
                        const SizedBox(height: 40),
                        const CircularProgressIndicator(color: AppConstants.accentOrange),
                        const SizedBox(height: 24),
                        Text(
                          message,
                          style: const TextStyle(color: Colors.white, fontSize: 20),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 32),
                        const Text('Hardware Key', style: TextStyle(color: Colors.white54, fontSize: 14)),
                        const SizedBox(height: 8),
                        SelectableText(
                          controller.hardwareKey,
                          style: TextStyle(
                            color: AppConstants.accentOrange,
                            fontSize: MediaQuery.sizeOf(context).width < 360 ? 14 : 18,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 48),
                        if (!syncing)
                          TextButton(
                            onPressed: controller.reconfigure,
                            child: const Text('Reconfigure', style: TextStyle(color: Colors.white54)),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}
