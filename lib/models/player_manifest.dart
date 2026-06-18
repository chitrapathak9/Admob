class ManifestMediaItem {
	final int order;
	final int layoutId;
	final int mediaId;
	final String name;
	final String type;
	final int duration;
	final int fileSize;
	final String md5;
	final String filename;
	final String downloadUrl;
	/// Layout canvas dimensions sent by the backend (0 when absent).
	final int layoutWidth;
	final int layoutHeight;

	const ManifestMediaItem({
		required this.order,
		required this.layoutId,
		required this.mediaId,
		required this.name,
		required this.type,
		required this.duration,
		required this.fileSize,
		required this.md5,
		required this.filename,
		required this.downloadUrl,
		this.layoutWidth = 0,
		this.layoutHeight = 0,
	});

	factory ManifestMediaItem.fromJson(Map<String, dynamic> json) {
		return ManifestMediaItem(
			order: (json['order'] as num?)?.toInt() ?? 0,
			layoutId: (json['layoutId'] as num?)?.toInt() ?? 0,
			mediaId: (json['mediaId'] as num?)?.toInt() ?? 0,
			name: json['name'] as String? ?? '',
			type: json['type'] as String? ?? 'image',
			duration: (json['duration'] as num?)?.toInt() ?? 10,
			fileSize: (json['fileSize'] as num?)?.toInt() ?? 0,
			md5: json['md5'] as String? ?? '',
			filename: json['filename'] as String? ?? '',
			downloadUrl: json['downloadUrl'] as String? ?? '',
			layoutWidth: (json['layoutWidth'] as num?)?.toInt() ?? 0,
			layoutHeight: (json['layoutHeight'] as num?)?.toInt() ?? 0,
		);
	}
}

class PlayerManifest {
	final int? displayId;
	final String displayName;
	final String groupName;
	final String manifestHash;
	final int collectionInterval;
	/// Max MB the /media/ dir may use before stale files are pruned. Backend-controlled via STORAGE_THRESHOLD_MB env.
	final int storageThresholdMb;
	final Map<String, dynamic>? schedule;
	final List<ManifestMediaItem> media;

	const PlayerManifest({
		this.displayId,
		required this.displayName,
		required this.groupName,
		required this.manifestHash,
		required this.collectionInterval,
		this.storageThresholdMb = 1024,
		this.schedule,
		required this.media,
	});

	factory PlayerManifest.fromJson(Map<String, dynamic> json) {
		final data = json['data'] as Map<String, dynamic>? ?? json;
		final mediaJson = data['media'] as List<dynamic>? ?? [];
		return PlayerManifest(
			displayId: (data['displayId'] as num?)?.toInt(),
			displayName: data['displayName'] as String? ?? '',
			groupName: data['groupName'] as String? ?? '',
			manifestHash: data['manifestHash'] as String? ?? '',
			collectionInterval: (data['collectionInterval'] as num?)?.toInt() ?? 60,
			storageThresholdMb: (data['storageThresholdMb'] as num?)?.toInt() ?? 1024,
			schedule: data['schedule'] as Map<String, dynamic>?,
			media: mediaJson
				.map((e) => ManifestMediaItem.fromJson(e as Map<String, dynamic>))
				.toList(),
		);
	}
}

class HeartbeatResult {
	final String action;

	const HeartbeatResult({required this.action});

	bool get shouldRefresh => action == 'refresh';
}
