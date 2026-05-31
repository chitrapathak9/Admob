import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../core/player_controller.dart';

/// Shows the backend diagnosis (Phase B1.2 endpoint) in a modal so operators can
/// see why a screen isn't playing — without Xibo access.
Future<void> showDiagnosticsDialog(BuildContext context, PlayerController controller) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: const Color(0xFF111111),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FutureBuilder<Map<String, dynamic>?>(
            future: controller.getDiagnostics(),
            builder: (ctx, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const SizedBox(
                  height: 160,
                  child: Center(child: CircularProgressIndicator(color: AppConstants.accentOrange)),
                );
              }
              final data = snap.data;
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Diagnostics',
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    SelectableText('Hardware Key: ${controller.hardwareKey}',
                        style: const TextStyle(color: Colors.white38, fontSize: 12)),
                    const Divider(color: Colors.white24, height: 24),
                    if (data == null)
                      const Text('Could not reach the diagnostics endpoint.',
                          style: TextStyle(color: Colors.redAccent))
                    else
                      ..._buildReport(data),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Close', style: TextStyle(color: AppConstants.accentOrange)),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

List<Widget> _buildReport(Map<String, dynamic> data) {
  final diagnosis = (data['diagnosis'] as Map?)?.cast<String, dynamic>() ?? {};
  final issues = (diagnosis['issues'] as List?)?.cast<dynamic>() ?? [];
  final healthy = diagnosis['isHealthy'] == true;
  final display = (data['display'] as Map?)?.cast<String, dynamic>();

  Widget row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('$label: $value', style: const TextStyle(color: Colors.white70, fontSize: 13)),
      );

  return [
    Text(
      healthy ? 'Healthy ✓' : 'Problems found',
      style: TextStyle(
        color: healthy ? Colors.greenAccent : Colors.orangeAccent,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    ),
    const SizedBox(height: 8),
    if (display != null) ...[
      row('Display', '${display['name'] ?? '—'} (id ${display['displayId'] ?? '—'})'),
      row('Authorised', '${display['authorised'] == true}'),
    ],
    row('In group', '${diagnosis['isInGroup'] == true}'),
    row('Has schedule', '${diagnosis['hasSchedule'] == true}'),
    row('Has layouts', '${diagnosis['hasLayouts'] == true}'),
    if (data['error'] == true)
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('(partial report — a CMS call failed)', style: TextStyle(color: Colors.white38, fontSize: 12)),
      ),
    if (issues.isNotEmpty) ...[
      const SizedBox(height: 12),
      const Text('Issues:', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      for (final issue in issues)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text('• $issue', style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)),
        ),
    ],
  ];
}
