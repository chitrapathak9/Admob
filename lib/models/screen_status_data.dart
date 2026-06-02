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
	bool get isExpired => status == 'expired';
	bool get isProcessing => status == 'processing';
	bool get isPending => status == 'pending';

	factory ScreenStatusData.fromJson(Map<String, dynamic> json) {
		final data = json['data'] as Map<String, dynamic>? ?? json;
		return ScreenStatusData(
			status: data['status'] as String,
			hardwareKey: data['hardwareKey'] as String,
			deviceId: data['deviceId'] as String,
			xiboDisplayId: (data['xiboDisplayId'] as num?)?.toInt(),
			displayName: data['displayName'] as String? ?? '',
			registeredAt: data['registeredAt'] != null ? DateTime.tryParse(data['registeredAt'] as String) : null,
			approvedAt: data['approvedAt'] != null ? DateTime.tryParse(data['approvedAt'] as String) : null,
			expiresAt: data['expiresAt'] != null ? DateTime.tryParse(data['expiresAt'] as String) : null,
			message: data['message'] as String? ?? '',
		);
	}
}
