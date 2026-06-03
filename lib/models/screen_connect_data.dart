class ScreenConnectData {
	final String deviceId;
	final String status;
	final String xmdsUrl;
	final String xmrUrl;
	final String cmsKey;
	final DateTime? expiresAt;
	final String message;

	const ScreenConnectData({
		required this.deviceId,
		required this.status,
		required this.xmdsUrl,
		required this.xmrUrl,
		required this.cmsKey,
		this.expiresAt,
		required this.message,
	});

	static String _str(dynamic value, [String fallback = '']) {
		if (value == null) return fallback;
		return value.toString();
	}

	factory ScreenConnectData.fromJson(Map<String, dynamic> json) {
		final data = json['data'] as Map<String, dynamic>? ?? json;
		return ScreenConnectData(
			deviceId: _str(data['deviceId']),
			status: _str(data['status'], 'pending'),
			xmdsUrl: data['xmdsUrl'] as String,
			xmrUrl: data['xmrUrl'] as String,
			cmsKey: data['cmsKey'] as String,
			expiresAt: data['expiresAt'] != null ? DateTime.tryParse(data['expiresAt'] as String) : null,
			message: data['message'] as String? ?? '',
		);
	}
}
