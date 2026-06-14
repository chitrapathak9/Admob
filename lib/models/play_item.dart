class PlayItem {
	final String localPath;
	final String type;
	final int duration;
	final String mediaId;
	final String layoutId;
	final int scheduleId;
	final String filename;
	final String name;
	// Revenue fields — default 0/empty means unlimited / no campaign association.
	final String campaignId;
	final int maxPerDay;
	final int maxPerMonth;
	final int dailyCapPerScreen;

	const PlayItem({
		required this.localPath,
		required this.type,
		required this.duration,
		this.mediaId = '',
		this.layoutId = '',
		this.scheduleId = 0,
		this.filename = '',
		this.name = '',
		this.campaignId = '',
		this.maxPerDay = 0,
		this.maxPerMonth = 0,
		this.dailyCapPerScreen = 0,
	});

	/// Media label for heartbeat — prefers display name, falls back to filename.
	String get displayName => name.isNotEmpty ? name : filename;

	@override
	bool operator ==(Object other) =>
		identical(this, other) ||
		other is PlayItem &&
			runtimeType == other.runtimeType &&
			localPath == other.localPath &&
			type == other.type &&
			duration == other.duration;

	@override
	int get hashCode => Object.hash(localPath, type, duration);
}
