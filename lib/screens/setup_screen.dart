import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../core/player_controller.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';

/// Setup screen (Phase F2.7). Dumb: collects Display Name + CMS Key and calls
/// `controller.configure(...)`. CMS URL is never shown — always backendBase.
/// Loading + error state are read from the controller.
class SetupScreen extends StatefulWidget {
  final PlayerController controller;
  const SetupScreen({super.key, required this.controller});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final _cmsKeyController = TextEditingController();
  final _nameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Pre-fill device model as the default display name.
    _nameController.text = widget.controller.displayName;
  }

  @override
  void dispose() {
    _cmsKeyController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _connect() {
    FocusScope.of(context).unfocus();
    widget.controller.configure(_nameController.text, _cmsKeyController.text);
  }

  @override
  Widget build(BuildContext context) {
    final padding = adaptiveScreenPadding(context);
    final logoHeight = adaptiveLogoHeight(context, large: 100, small: 72);
    final titleSize = adaptiveTitleSize(context);

    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final busy = widget.controller.isBusy;
        final error = widget.controller.errorMessage;
        return Scaffold(
          backgroundColor: AppConstants.background,
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
                      _field(label: 'Display Name', controller: _nameController),
                      const SizedBox(height: 20),
                      _field(label: 'CMS Key', controller: _cmsKeyController),
                      if (error != null) ...[
                        const SizedBox(height: 16),
                        Text(
                          error,
                          style: const TextStyle(color: Colors.redAccent),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 32),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: busy ? null : _connect,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppConstants.accentOrange,
                            foregroundColor: Colors.black,
                          ),
                          child: busy
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Connect', style: TextStyle(fontSize: 18)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _field({required String label, required TextEditingController controller}) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: Colors.white24),
          borderRadius: BorderRadius.circular(8),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppConstants.accentOrange),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}
