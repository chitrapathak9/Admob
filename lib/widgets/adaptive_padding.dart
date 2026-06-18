import 'package:flutter/material.dart';

/// Responsive horizontal padding for setup/waiting on phones, tablets, and TVs.
EdgeInsets adaptiveScreenPadding(BuildContext context) {
	final width = MediaQuery.sizeOf(context).width;
	final horizontal = width < 360
		? 16.0
		: width < 600
			? 24.0
			: width < 900
				? 32.0
				: 48.0;
	return EdgeInsets.symmetric(horizontal: horizontal, vertical: 24);
}

double adaptiveLogoHeight(BuildContext context, {double large = 120, double small = 80}) {
	return MediaQuery.sizeOf(context).shortestSide < 400 ? small : large;
}

double adaptiveTitleSize(BuildContext context) {
	final width = MediaQuery.sizeOf(context).width;
	if (width < 360) return 18;
	if (width < 600) return 20;
	return 22;
}

/// Returns a smaller gap in landscape where vertical space is scarce.
double adaptiveGap(BuildContext context, {double portrait = 40, double landscape = 16}) {
	final size = MediaQuery.sizeOf(context);
	return size.width > size.height ? landscape : portrait;
}

/// Logo height that shrinks further in landscape to preserve vertical space.
double adaptiveLogoHeightOriented(
	BuildContext context, {
	double portrait = 100,
	double landscape = 60,
}) {
	final size = MediaQuery.sizeOf(context);
	return size.width > size.height ? landscape : portrait;
}
