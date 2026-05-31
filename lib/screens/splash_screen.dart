import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../widgets/adaptive_padding.dart';
import '../widgets/theadbook_logo.dart';

/// Pure visual splash (Phase F2.7). The controller drives initialization +
/// routing — this screen has no logic and no navigation.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.background,
      body: Center(
        child: TheadbookLogo(
          height: adaptiveLogoHeight(context, large: 160, small: 100),
        ),
      ),
    );
  }
}
