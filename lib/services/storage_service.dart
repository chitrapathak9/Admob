import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/player_config.dart';
import '../models/screen_connect_data.dart';

const kXmdsUrl = 'xmds_url';
const kXmrUrl = 'xmr_url';
const kCmsKey = 'cms_key';
const kHardwareKey = 'hardware_key';
const kDisplayName = 'display_name';
const kDeviceId = 'device_id';
const kUserCmsKey = 'user_cms_key';
const kCollectionInterval = 'collection_interval';
const kIsApproved = 'is_approved';
const kRegistrationStatus = 'registration_status';
const kManifestHash = 'manifest_hash';
const kCurrentLayoutId = 'current_layout_id';
const kConfigJson = 'player_config_json';
const kScreenConnectCompleted = 'screen_connect_completed';

class StorageService {
	StorageService._();
	static final StorageService instance = StorageService._();

	SharedPreferences? _prefs;

	Future<SharedPreferences> get prefs async {
		_prefs ??= await SharedPreferences.getInstance();
		return _prefs!;
	}

	Future<void> saveConnectResult(ScreenConnectData connect) async {
		final config = PlayerConfig(
			xmdsUrl: connect.xmdsUrl,
			xmrUrl: connect.xmrUrl,
			cmsKey: connect.cmsKey,
			version: '5',
			collectionInterval: 60,
		);
		await saveConfig(config);
		final p = await prefs;
		await p.setString(kDeviceId, connect.deviceId);
		await p.setString(kRegistrationStatus, connect.status);
		await p.setBool(kScreenConnectCompleted, true);
	}

	Future<void> saveRegistrationStatus(String status) async {
		final p = await prefs;
		await p.setString(kRegistrationStatus, status);
	}

	Future<String?> loadRegistrationStatus() async {
		final p = await prefs;
		return p.getString(kRegistrationStatus);
	}

	Future<String?> loadDeviceId() async {
		final p = await prefs;
		return p.getString(kDeviceId);
	}

	Future<void> saveConfig(PlayerConfig config) async {
		final p = await prefs;
		await p.setString(kXmdsUrl, config.xmdsUrl);
		await p.setString(kXmrUrl, config.xmrUrl);
		await p.setString(kCmsKey, config.cmsKey);
		await p.setInt(kCollectionInterval, config.collectionInterval);
		await p.setString(kConfigJson, jsonEncode(config.toJson()));
	}

	Future<PlayerConfig?> loadConfig() async {
		final p = await prefs;
		final jsonStr = p.getString(kConfigJson);
		if (jsonStr != null) {
			return PlayerConfig.fromJson(jsonDecode(jsonStr) as Map<String, dynamic>);
		}
		final xmds = p.getString(kXmdsUrl);
		final cms = p.getString(kCmsKey);
		if (xmds == null || cms == null) return null;
		return PlayerConfig(
			xmdsUrl: xmds,
			xmrUrl: p.getString(kXmrUrl) ?? '',
			cmsKey: cms,
			version: '5',
			collectionInterval: p.getInt(kCollectionInterval) ?? 60,
		);
	}

	Future<String> getOrCreateHardwareKey() async {
		final p = await prefs;
		final existing = p.getString(kHardwareKey);
		if (existing != null && existing.isNotEmpty) return existing;

		String hardwareKey = '';
		try {
			final plugin = DeviceInfoPlugin();
			if (!kIsWeb && Platform.isAndroid) {
				hardwareKey = (await plugin.androidInfo).id;
			} else if (!kIsWeb && Platform.isIOS) {
				hardwareKey = (await plugin.iosInfo).identifierForVendor ?? '';
			}
		} catch (_) {}

		if (hardwareKey.isEmpty || hardwareKey == 'unknown') {
			hardwareKey = const Uuid().v4();
		}

		await p.setString(kHardwareKey, hardwareKey);
		return hardwareKey;
	}

	Future<String?> loadHardwareKey() async {
		final p = await prefs;
		return p.getString(kHardwareKey);
	}

	Future<void> saveHardwareKey(String key) async {
		final p = await prefs;
		await p.setString(kHardwareKey, key);
	}

	Future<void> saveDisplayName(String name) async {
		final p = await prefs;
		await p.setString(kDisplayName, name);
	}

	Future<String?> loadDisplayName() async {
		final p = await prefs;
		return p.getString(kDisplayName);
	}

	Future<void> saveUserCmsKey(String key) async {
		final p = await prefs;
		await p.setString(kUserCmsKey, key);
	}

	Future<bool> isApproved() async {
		final p = await prefs;
		return p.getBool(kIsApproved) ?? false;
	}

	Future<void> setApproved(bool value) async {
		final p = await prefs;
		await p.setBool(kIsApproved, value);
	}

	Future<void> setCurrentLayoutId(String id) async {
		final p = await prefs;
		await p.setString(kCurrentLayoutId, id);
	}

	Future<String?> getCurrentLayoutId() async {
		final p = await prefs;
		return p.getString(kCurrentLayoutId);
	}

	Future<int> getCollectionInterval() async {
		final p = await prefs;
		return p.getInt(kCollectionInterval) ?? 60;
	}

	Future<String?> getCmsKey() async {
		final p = await prefs;
		return p.getString(kCmsKey);
	}

	Future<String?> getXmdsUrl() async {
		final p = await prefs;
		return p.getString(kXmdsUrl);
	}

	Future<String?> getXmrUrl() async {
		final p = await prefs;
		return p.getString(kXmrUrl);
	}

	Future<void> clearAll() async {
		final p = await prefs;
		final hardwareKey = p.getString(kHardwareKey);
		await p.clear();
		if (hardwareKey != null) {
			await p.setString(kHardwareKey, hardwareKey);
		}
	}

	Future<bool> hasConfig() async => (await loadConfig()) != null;

	/// True only after [saveConnectResult] — not from GET /player/config alone.
	Future<bool> hasCompletedScreenConnect() async {
		final p = await prefs;
		return p.getBool(kScreenConnectCompleted) ?? false;
	}

	Future<bool> hasPendingRegistration() async {
		if (await isApproved()) return false;
		return await hasCompletedScreenConnect();
	}

	Future<void> saveManifestHash(String hash) async {
		final p = await prefs;
		await p.setString(kManifestHash, hash);
	}

	Future<String?> loadManifestHash() async {
		final p = await prefs;
		return p.getString(kManifestHash);
	}
}
