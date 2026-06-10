/// Detects when the backend reports that a device is no longer registered.
class RegistrationErrors {
	RegistrationErrors._();

	static const _codes = {
		'NOT_REGISTERED',
		'DEVICE_NOT_FOUND',
		'REGISTRATION_NOT_FOUND',
		'DEVICE_NOT_REGISTERED',
	};

	static bool isNotRegistered({String? code, String? message}) {
		if (code != null && _codes.contains(code.toUpperCase())) {
			return true;
		}
		if (message == null) return false;
		final lower = message.toLowerCase();
		return lower.contains('not registered') ||
			lower.contains('device not found') ||
			lower.contains('registration not found') ||
			lower.contains('register not found');
	}
}
