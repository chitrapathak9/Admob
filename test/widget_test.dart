import 'package:flutter_test/flutter_test.dart';
import 'package:theadbook_player/config/app_constants.dart';

/// Smoke test for the canonical constants (Phase F2.1). Full app/widget flows
/// are covered by the F2.10 on-device integration suite — pumping the real app
/// here would fire network + platform-channel calls that don't exist in the
/// headless test harness. See state_machine_test.dart for logic coverage.
void main() {
  test('AppConstants are wired to the production backend', () {
    expect(AppConstants.backendBase, startsWith('https://'));
    expect(AppConstants.scheduleRefreshSeconds, greaterThan(0));
    expect(AppConstants.statusPollIntervalSeconds, greaterThan(0));
    expect(AppConstants.skipExtensions, contains('ttf'));
    expect(AppConstants.mediaExtensions, contains('mp4'));
  });
}
