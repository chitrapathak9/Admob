/// On-device status for RequiredFiles (dependencies, layouts, campaign media).
class DownloadProgress {
	final int filesReady;
	final int filesTotal;
	final int dependenciesReady;
	final int dependenciesTotal;
	final int layoutsReady;
	final int layoutsTotal;
	final int campaignMediaReady;
	final int campaignMediaTotal;

	const DownloadProgress({
		this.filesReady = 0,
		this.filesTotal = 0,
		this.dependenciesReady = 0,
		this.dependenciesTotal = 0,
		this.layoutsReady = 0,
		this.layoutsTotal = 0,
		this.campaignMediaReady = 0,
		this.campaignMediaTotal = 0,
	});

	bool get allRequiredOnDisk => filesTotal > 0 && filesReady >= filesTotal;
}
