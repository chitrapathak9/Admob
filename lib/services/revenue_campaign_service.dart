import '../utils/app_logger.dart';

/// Tracks which revenue campaigns are currently paused (prepaid balance
/// exhausted) based on real-time socket events from the backend.
///
/// The service is the single source of truth for campaign pause state on the
/// player. `SocketEventHandler` writes to it; `player_screen` reads from it
/// via [isCampaignPaused] to filter the active playlist.
class RevenueCampaignService {
	RevenueCampaignService._();
	static final RevenueCampaignService instance = RevenueCampaignService._();

	final Set<String> _pausedCampaignIds = {};

	/// Called when the backend emits `campaign:paused`.
	void disableCampaign(String campaignId) {
		if (campaignId.isEmpty) return;
		_pausedCampaignIds.add(campaignId);
		AppLogger.api('RevCampaign', 'campaign paused — id=$campaignId '
			'(total paused: ${_pausedCampaignIds.length})');
	}

	/// Called when the backend emits `campaign:reactivated`.
	void reEnableCampaign(String campaignId) {
		if (campaignId.isEmpty) return;
		_pausedCampaignIds.remove(campaignId);
		AppLogger.api('RevCampaign', 'campaign reactivated — id=$campaignId '
			'(total paused: ${_pausedCampaignIds.length})');
	}

	/// Returns true if [campaignId] has been paused by the backend.
	/// An empty string (no campaign association) is never paused.
	bool isCampaignPaused(String campaignId) {
		if (campaignId.isEmpty) return false;
		return _pausedCampaignIds.contains(campaignId);
	}

	/// True when every active playlist slot has a paused campaign — used to
	/// trigger fallback content display.
	bool areAllCampaignsPaused(List<String> campaignIds) {
		if (campaignIds.isEmpty) return false;
		final nonEmpty = campaignIds.where((id) => id.isNotEmpty).toList();
		if (nonEmpty.isEmpty) return false;
		return nonEmpty.every(_pausedCampaignIds.contains);
	}

	/// Clears all paused state — called on WebSocket reconnect to force a
	/// resync with the server manifest.
	void clear() {
		_pausedCampaignIds.clear();
		AppLogger.api('RevCampaign', 'paused-campaign state cleared (reconnect resync)');
	}

	int get pausedCount => _pausedCampaignIds.length;
}
