class ScreenStatusData {
	final String status;
	final String hardwareKey;
	final String deviceId;
	final int? xiboDisplayId;
	final String displayName;
	final DateTime? registeredAt;
	final DateTime? approvedAt;
	final DateTime? expiresAt;
	final String message;

	const ScreenStatusData({
		required this.status,
		required this.hardwareKey,
		required this.deviceId,
		this.xiboDisplayId,
		required this.displayName,
		this.registeredAt,
		this.approvedAt,
		this.expiresAt,
		required this.message,
	});

	bool get isApproved => status == 'approved';
	bool get isActive => status == 'active';
	bool get isApprovedOrActive => isApproved || isActive;
	bool get isExpired => status == 'expired';
	bool get isProcessing => status == 'processing';
	bool get isPending => status == 'pending';

	/// Backend returns this when POST /screens/connect was never called.
	bool get needsConnectFirst =>
		deviceId.isEmpty &&
		(message.toLowerCase().contains('connect') ||
			message.toLowerCase().contains('not initiated') ||
			message.toLowerCase().contains('registration'));

	static String _str(dynamic value, [String fallback = '']) {
		if (value == null) return fallback;
		return value.toString();
	}

	factory ScreenStatusData.fromJson(Map<String, dynamic> json) {
		final data = json['data'] as Map<String, dynamic>? ?? json;
		return ScreenStatusData(
			status: _str(data['status'], 'pending'),
			hardwareKey: _str(data['hardwareKey']),
			deviceId: _str(data['deviceId']),
			xiboDisplayId: (data['xiboDisplayId'] as num?)?.toInt(),
			displayName: _str(data['displayName']),
			registeredAt: data['registeredAt'] != null ? DateTime.tryParse(data['registeredAt'] as String) : null,
			approvedAt: data['approvedAt'] != null ? DateTime.tryParse(data['approvedAt'] as String) : null,
			expiresAt: data['expiresAt'] != null ? DateTime.tryParse(data['expiresAt'] as String) : null,
			message: data['message'] as String? ?? '',
		);
	}
}
