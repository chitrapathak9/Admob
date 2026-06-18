class PlayItem {
	final String localPath;
	final String type;
	final int duration;
	final String mediaId;
	final String layoutId;
	final int scheduleId;
	final String filename;
	final String name;
	/// Layout canvas dimensions (0 when unknown — derived from manifest or XLF).
	final int layoutWidth;
	final int layoutHeight;

	const PlayItem({
		required this.localPath,
		required this.type,
		required this.duration,
		this.mediaId = '',
		this.layoutId = '',
		this.scheduleId = 0,
		this.filename = '',
		this.name = '',
		this.layoutWidth = 0,
		this.layoutHeight = 0,
	});

	/// True when the backend or XLF supplied explicit canvas dimensions.
	bool get hasKnownOrientation => layoutWidth > 0 && layoutHeight > 0;

	/// Canvas is wider than it is tall (16:9, 4:3, etc.).
	bool get isLandscapeLayout => hasKnownOrientation && layoutWidth >= layoutHeight;

	/// Canvas is taller than it is wide (9:16, etc.).
	bool get isPortraitLayout => hasKnownOrientation && layoutHeight > layoutWidth;

	/// Media label for heartbeat — prefers display name, falls back to filename.
	String get displayName => name.isNotEmpty ? name : filename;

	@override
	bool operator ==(Object other) =>
		identical(this, other) ||
		other is PlayItem &&
			runtimeType == other.runtimeType &&
			localPath == other.localPath &&
			type == other.type &&
			duration == other.duration &&
			layoutWidth == other.layoutWidth &&
			layoutHeight == other.layoutHeight;

	@override
	int get hashCode => Object.hash(localPath, type, duration, layoutWidth, layoutHeight);
}
