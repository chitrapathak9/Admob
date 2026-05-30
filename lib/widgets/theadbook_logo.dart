import 'package:flutter/material.dart';

import '../config/app_config.dart';

class TheadbookLogo extends StatelessWidget {
	final double height;

	const TheadbookLogo({super.key, this.height = 120});

	@override
	Widget build(BuildContext context) {
		return Image.asset(
			'assets/logo.png',
			height: height,
			fit: BoxFit.contain,
			errorBuilder: (_, __, ___) => Column(
				mainAxisSize: MainAxisSize.min,
				children: [
					Text(
						'theadbook',
						style: TextStyle(
							fontSize: height * 0.35,
							fontWeight: FontWeight.bold,
							color: AppConfig.accentOrange,
							letterSpacing: 2,
						),
					),
					const SizedBox(height: 8),
					Text(
						'Player',
						style: TextStyle(
							fontSize: height * 0.2,
							color: Colors.white70,
							letterSpacing: 4,
						),
					),
				],
			),
		);
	}
}
