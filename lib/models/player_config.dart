class PlayerConfig {
	final String xmdsUrl;
	final String xmrUrl;
	final String cmsKey;
	final String version;
	final int collectionInterval;
	final String? supportEmail;

	const PlayerConfig({
		required this.xmdsUrl,
		required this.xmrUrl,
		required this.cmsKey,
		required this.version,
		required this.collectionInterval,
		this.supportEmail,
	});

	factory PlayerConfig.fromJson(Map<String, dynamic> json) {
		final data = json['data'] as Map<String, dynamic>? ?? json;
		return PlayerConfig(
			xmdsUrl: data['xmdsUrl'] as String,
			xmrUrl: data['xmrUrl'] as String,
			cmsKey: data['cmsKey'] as String,
			version: data['version']?.toString() ?? '5',
			collectionInterval: (data['collectionInterval'] as num?)?.toInt() ?? 60,
			supportEmail: data['supportEmail'] as String?,
		);
	}

	Map<String, dynamic> toJson() => {
		'xmdsUrl': xmdsUrl,
		'xmrUrl': xmrUrl,
		'cmsKey': cmsKey,
		'version': version,
		'collectionInterval': collectionInterval,
		'supportEmail': supportEmail,
	};
}
