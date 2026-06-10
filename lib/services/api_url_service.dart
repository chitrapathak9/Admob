import '../config/app_config.dart';
import 'config_service.dart';
import 'player_service.dart';
import 'screen_service.dart';
import 'storage_service.dart';

class ApiUrlService {
	ApiUrlService._();
	static final ApiUrlService instance = ApiUrlService._();

	Future<void> initialize() async {
		final saved = await StorageService.instance.loadApiBaseUrl();
		_applyBaseUrl(saved ?? AppConfig.defaultBaseUrl);
	}

	Future<void> setBaseUrl(String url) async {
		final normalized = _normalize(url);
		_applyBaseUrl(normalized);
		await StorageService.instance.saveApiBaseUrl(normalized);
	}

	void _applyBaseUrl(String url) {
		AppConfig.setRuntimeBaseUrl(url);
		ScreenService.instance.updateBaseUrl();
		PlayerService.instance.updateBaseUrl();
		ConfigService.instance.updateBaseUrl();
	}

	String _normalize(String url) {
		var normalized = url.trim();
		while (normalized.endsWith('/')) {
			normalized = normalized.substring(0, normalized.length - 1);
		}
		return normalized.isEmpty ? AppConfig.defaultBaseUrl : normalized;
	}
}
