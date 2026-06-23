import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_config.dart';
import '../services/battery_optimization_service.dart';
import '../services/overlay_permission_service.dart';

// ── Permission result ─────────────────────────────────────────────────────────

class PermissionResult {
  final bool batteryExempt;
  final bool overlayGranted;
  final bool wakelockEnabled;

  const PermissionResult({
    required this.batteryExempt,
    required this.overlayGranted,
    required this.wakelockEnabled,
  });

  bool get allGranted => batteryExempt && overlayGranted && wakelockEnabled;
}

// ── Public helper ─────────────────────────────────────────────────────────────

/// Shows the permission flow dialog and returns a [PermissionResult].
/// The dialog is non-dismissible — the user must tap Continue after the
/// permission steps finish (granted or denied).
Future<PermissionResult?> showPermissionFlowDialog(BuildContext context) {
  return showDialog<PermissionResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const _PermissionFlowDialog(),
  );
}

// ── Dialog widget ─────────────────────────────────────────────────────────────

enum _Step {
  explanation,   // "Why we need these"
  battery,       // requesting battery optimisation exemption
  overlay,       // requesting display-over-other-apps permission
  wakelock,      // enabling always-on display
  summary,       // results + Continue button
}

class _PermissionFlowDialog extends StatefulWidget {
  const _PermissionFlowDialog();

  @override
  State<_PermissionFlowDialog> createState() => _PermissionFlowDialogState();
}

class _PermissionFlowDialogState extends State<_PermissionFlowDialog> {
  _Step _step = _Step.explanation;
  bool? _batteryGranted;
  bool? _overlayGranted;
  bool? _wakelockGranted;

  // ── Step runners ────────────────────────────────────────────────────────────

  Future<void> _runPermissions() async {
    // ── Step 1: Battery Optimisation ─────────────────────────────────────────
    setState(() => _step = _Step.battery);
    final battery =
        await BatteryOptimizationService.requestIgnoreBatteryOptimizations();
    setState(() => _batteryGranted = battery);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    // ── Step 2: Display Over Other Apps ──────────────────────────────────────
    // Opens Settings.ACTION_MANAGE_OVERLAY_PERMISSION — user toggles the switch
    // in the system settings screen and we read the result on return.
    setState(() => _step = _Step.overlay);
    final overlay = await OverlayPermissionService.requestOverlayPermission();
    setState(() => _overlayGranted = overlay);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    // ── Step 3: Wakelock (Keep Screen On) ────────────────────────────────────
    // WAKE_LOCK is a normal manifest permission — auto-granted at install.
    // No system popup is shown; we simply enable it programmatically.
    setState(() => _step = _Step.wakelock);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    bool wakelock = false;
    try {
      await WakelockPlus.enable();
      wakelock = true;
    } catch (_) {
      wakelock = false;
    }
    setState(() {
      _wakelockGranted = wakelock;
      _step = _Step.summary;
    });
  }

  void _close() {
    Navigator.of(context).pop(
      PermissionResult(
        batteryExempt: _batteryGranted ?? false,
        overlayGranted: _overlayGranted ?? false,
        wakelockEnabled: _wakelockGranted ?? false,
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
      title: _buildTitle(),
      content: AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        child: KeyedSubtree(
          key: ValueKey(_step),
          child: _buildStepContent(),
        ),
      ),
    );
  }

  Widget _buildTitle() {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppConfig.accentOrange.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(
            Icons.shield_outlined,
            color: AppConfig.accentOrange,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            _step == _Step.explanation
                ? 'App Permissions Required'
                : _step == _Step.summary
                    ? 'Permission Status'
                    : 'Requesting Permissions…',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStepContent() {
    switch (_step) {
      case _Step.explanation:
        return _buildExplanation();
      case _Step.battery:
        return _buildBatteryStep();
      case _Step.overlay:
        return _buildOverlayStep();
      case _Step.wakelock:
        return _buildWakelockStep();
      case _Step.summary:
        return _buildSummary();
    }
  }

  // ── Explanation ─────────────────────────────────────────────────────────────

  Widget _buildExplanation() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'To run as a reliable digital signage display, this app needs three system permissions. We\'ll request them one at a time.',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 20),
        _explanationRow(
          step: '1',
          icon: Icons.battery_saver_outlined,
          title: 'Battery Optimization Exempt',
          description:
              'Android will show a system dialog. Tap "Allow" so the app keeps running without interruption.',
        ),
        const SizedBox(height: 14),
        _explanationRow(
          step: '2',
          icon: Icons.layers_outlined,
          title: 'Display Over Other Apps',
          description:
              'Opens Android Settings. Enable the toggle so this app can appear on top of other apps at all times.',
        ),
        const SizedBox(height: 14),
        _explanationRow(
          step: '3',
          icon: Icons.brightness_high_outlined,
          title: 'Keep Screen On',
          description:
              'Prevents the display from sleeping during playback. Enabled automatically — no popup required.',
        ),
        const SizedBox(height: 20),
        _infoBox(
          'You can still register the device if a permission is denied, but playback may be interrupted.',
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white38),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: _runPermissions,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppConfig.accentOrange,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Grant Permissions'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _explanationRow({
    required String step,
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.only(top: 2),
          decoration: BoxDecoration(
            color: AppConfig.accentOrange.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              step,
              style: const TextStyle(
                color: AppConfig.accentOrange,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: AppConfig.accentOrange, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                description,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Battery step ────────────────────────────────────────────────────────────

  Widget _buildBatteryStep() {
    final granted = _batteryGranted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepProgressBar(current: 1),
        const SizedBox(height: 24),
        _stepIcon(Icons.battery_saver_outlined, granted: granted),
        const SizedBox(height: 16),
        const Text(
          'Battery Optimization Exempt',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          granted == null
              ? 'A system dialog has opened.\nTap "Allow" to grant this permission.'
              : granted
                  ? 'Permission granted successfully.'
                  : 'Permission denied. Playback may be interrupted in the background.',
          style: TextStyle(
            color: granted == null
                ? Colors.white54
                : granted
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
            fontSize: 13,
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (granted == null)
          const CircularProgressIndicator(
            color: AppConfig.accentOrange,
            strokeWidth: 2,
          )
        else
          _statusChip(granted: granted),
      ],
    );
  }

  // ── Overlay step ────────────────────────────────────────────────────────────

  Widget _buildOverlayStep() {
    final granted = _overlayGranted;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepProgressBar(current: 2),
        const SizedBox(height: 24),
        _stepIcon(Icons.layers_outlined, granted: granted),
        const SizedBox(height: 16),
        const Text(
          'Display Over Other Apps',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          granted == null
              ? 'Settings has opened.\nFind this app and enable "Allow display over other apps".'
              : granted
                  ? 'Permission granted successfully.'
                  : 'Permission denied. Content may be hidden behind other apps.',
          style: TextStyle(
            color: granted == null
                ? Colors.white54
                : granted
                    ? Colors.greenAccent
                    : Colors.orangeAccent,
            fontSize: 13,
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (granted == null)
          const CircularProgressIndicator(
            color: AppConfig.accentOrange,
            strokeWidth: 2,
          )
        else
          _statusChip(granted: granted),
      ],
    );
  }

  // ── Wakelock step ───────────────────────────────────────────────────────────

  Widget _buildWakelockStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _stepProgressBar(current: 3),
        const SizedBox(height: 24),
        _stepIcon(Icons.brightness_high_outlined, granted: null),
        const SizedBox(height: 16),
        const Text(
          'Keep Screen On',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Enabling always-on display…',
          style: TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        const CircularProgressIndicator(
          color: AppConfig.accentOrange,
          strokeWidth: 2,
        ),
      ],
    );
  }

  // ── Summary ─────────────────────────────────────────────────────────────────

  Widget _buildSummary() {
    final batteryOk = _batteryGranted ?? false;
    final overlayOk = _overlayGranted ?? false;
    final wakelockOk = _wakelockGranted ?? false;
    final allOk = batteryOk && overlayOk && wakelockOk;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _summaryRow(
          icon: Icons.battery_saver_outlined,
          label: 'Battery Optimization Exempt',
          granted: batteryOk,
        ),
        const SizedBox(height: 12),
        _summaryRow(
          icon: Icons.layers_outlined,
          label: 'Display Over Other Apps',
          granted: overlayOk,
        ),
        const SizedBox(height: 12),
        _summaryRow(
          icon: Icons.brightness_high_outlined,
          label: 'Keep Screen On',
          granted: wakelockOk,
        ),
        if (!allOk) ...[
          const SizedBox(height: 16),
          _infoBox(
            'Some permissions were not granted. You can still register the device, '
            'but uninterrupted playback is not guaranteed. You can grant permissions '
            'later in Android Settings.',
            isWarning: true,
          ),
        ],
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _close,
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  allOk ? AppConfig.accentOrange : Colors.white24,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: Text(
              allOk ? 'Continue to Registration' : 'Continue Anyway',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _summaryRow({
    required IconData icon,
    required String label,
    required bool granted,
  }) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: granted
                ? Colors.greenAccent.withValues(alpha: 0.12)
                : Colors.redAccent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                granted ? Icons.check_circle_outline : Icons.cancel_outlined,
                color: granted ? Colors.greenAccent : Colors.redAccent,
                size: 14,
              ),
              const SizedBox(width: 4),
              Text(
                granted ? 'Granted' : 'Denied',
                style: TextStyle(
                  color: granted ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Shared helpers ──────────────────────────────────────────────────────────

  Widget _stepProgressBar({required int current}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(3, (i) {
        final active = i + 1 == current;
        final done = i + 1 < current;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 32 : 10,
          height: 6,
          decoration: BoxDecoration(
            color: done || active
                ? AppConfig.accentOrange
                : Colors.white12,
            borderRadius: BorderRadius.circular(3),
          ),
        );
      }),
    );
  }

  Widget _stepIcon(IconData icon, {required bool? granted}) {
    Color bg;
    Color fg;
    if (granted == null) {
      bg = AppConfig.accentOrange.withValues(alpha: 0.15);
      fg = AppConfig.accentOrange;
    } else if (granted) {
      bg = Colors.greenAccent.withValues(alpha: 0.12);
      fg = Colors.greenAccent;
    } else {
      bg = Colors.redAccent.withValues(alpha: 0.12);
      fg = Colors.redAccent;
    }
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Icon(icon, color: fg, size: 30),
    );
  }

  Widget _statusChip({required bool granted}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: granted
            ? Colors.greenAccent.withValues(alpha: 0.12)
            : Colors.redAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            granted ? Icons.check_circle_outline : Icons.cancel_outlined,
            color: granted ? Colors.greenAccent : Colors.redAccent,
            size: 16,
          ),
          const SizedBox(width: 6),
          Text(
            granted ? 'Granted' : 'Denied',
            style: TextStyle(
              color: granted ? Colors.greenAccent : Colors.redAccent,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoBox(String text, {bool isWarning = false}) {
    final color = isWarning ? Colors.orangeAccent : AppConfig.accentOrange;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isWarning ? Icons.warning_amber_rounded : Icons.info_outline,
            color: color,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 12, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
