import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Display name for RegisterDisplay — works on phones, tablets, TV, foldables, etc.
Future<String> defaultDisplayName() async {
	if (kIsWeb) return 'theadbook Screen';
	try {
		final plugin = DeviceInfoPlugin();
		if (Platform.isAndroid) {
			final info = await plugin.androidInfo;
			final model = info.model.trim();
			final manufacturer = info.manufacturer.trim();
			if (model.isNotEmpty && manufacturer.isNotEmpty) {
				return '$manufacturer $model';
			}
			return model.isNotEmpty ? model : 'Android Screen';
		}
		if (Platform.isIOS) {
			final info = await plugin.iosInfo;
			return info.name.trim().isNotEmpty ? info.name : 'iOS Screen';
		}
		if (Platform.isLinux) return 'Linux Screen';
		if (Platform.isMacOS) return 'macOS Screen';
		if (Platform.isWindows) return 'Windows Screen';
	} catch (_) {}
	return 'theadbook Screen';
}

String registerOperatingSystem() {
	if (kIsWeb) return 'Web';
	if (Platform.isAndroid) return 'Android';
	if (Platform.isIOS) return 'iOS';
	return Platform.operatingSystem;
}
